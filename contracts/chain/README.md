# Intent Chaining

`IntentChainer` (`IntentChainer.sol`) publishes an intent whose amount does not exist
until another intent executes.

## The problem

An intent's reward amount is part of `Reward`, which is part of the intent hash, which is the CREATE2 salt
for its vault. So an intent whose amount is only known at execution time cannot be built, hashed, or funded
ahead of time — the vault address itself moves with the amount.

That blocks any flow where one intent's output feeds another's input. The motivating case is a cross-chain
swap expressed as two intents:

```
Arbitrum                                            Base / Solana
────────────────────────────────────────            ─────────────────────
intent1  (same-chain, ARB → ARB)
  route.tokens  [WETH, amountIn]
  route.calls
    [0] WETH.transfer(swapper, amountIn)
    [1] swapper.swap(→ IntentChainer)      ── produces an amount nobody knew in advance
    [2] IntentChainer.chain(order)
                                  │
                                  ├─ measures its USDC balance          = amountIn
                                  ├─ publishes intent2                   (route carries the scaled amount)
                                  └─ pushes amountIn into intent2's vault
                                                    │
intent2  (ARB → BASE)                               ▼
  reward.tokens [USDC, amountIn]          solver delivers the scaled amount on the destination,
  route         amountIn * scale          whose calls swap it and pay the user
```

The user signs and funds only intent1. Everything after that is solver-executed.

## What the chainer does

Called as the last `Call` of an executing intent, it:

1. measures its own balance of one ERC20 — the single runtime measurement in the whole flow
2. rebuilds intent2's route with that amount spliced in
3. calls `Portal.publish`, which returns intent2's vault address
4. transfers the measured balance into that vault

`publish` runs **before** the transfer, because it hands back the vault address — which cannot be derived
here — and because every failure should revert the outer intent whole rather than strand tokens in a vault
that cannot pay out.

It does **not** reject every colliding hash, and the gap is the operating window rather than an edge.
`IntentSource._validatePublish` refuses only `Withdrawn` and `Refunded`; re-publishing an `Initial` or
`Funded` intent is deliberately idempotent. Since the chainer never funds intent2, it sits at `Initial` for
its whole useful life — so a second `chain` on a colliding order would re-publish and push a second
`amountIn` into the same vault, merging two chains into one intent with no signal. The vault balance read
immediately before the transfer is what closes that; `publish` closes only the terminal half.

## Two amounts, one measurement

| value                          | goes to                   | meaning                                                |
| ------------------------------ | ------------------------- | ------------------------------------------------------ |
| `amountIn`                     | `reward.tokens[0].amount` | escrowed on the source; what intent2's solver collects |
| `ceil(amountIn * scale / WAD)` | every route slot          | what that solver must deliver on the destination       |

One committed number, `scale`, does the whole source-to-destination transform. The reward leg escrows the
full measured `amountIn` while the route obliges only the scaled amount, so the gap between them is
intent2's solver's entire margin.

### Units are not the same across chains

Part of `scale` is a unit conversion, needed because "the same token" is not the same unit everywhere:
USDC is 6 decimals on Ethereum, Base and Solana, but Binance-Peg USDC on BNB Chain is 18, and Arc's native
USDC is 18 against a 6-decimal ERC20 wrapper — see `NATIVE_USDC_SCALING` in
`../deposit/DepositAddress_CCTPMint_Arc.sol`.

| lane                         | `scale`           |
| ---------------------------- | ----------------- |
| same units, no spread        | `1e18`            |
| same units, less 100bps      | `0.99e18`         |
| 6 → 18 decimals              | `1e30`            |
| 18 → 6 decimals              | `1e6`             |
| 6 → 18 decimals, less 100bps | `1e30 * 99 / 100` |

The denominator is **decimal, not binary**, on purpose. Unit conversions are powers of ten, so a decimal
denominator represents every one of them exactly in both directions; a binary denominator (Q128 and
friends) cannot — `2^128 / 1e12` is not an integer, so a downscaling lane would lean on rounding to
recover a value it should have computed exactly.

### The spread is proportional, not flat

There is no separate flat fee field. A flat fee and a ratio are different functions of `amountIn` — flat
keeps the solver's take constant as the amount moves, proportional lets it grow — and a flat one cannot be
folded into a ratio. The trade is deliberate:

- **Lost:** pricing destination gas independently of size, which is genuinely fixed.
- **Kept:** everything else, because the only thing that moves `amountIn` here is swap slippage, a percent
  or so around a known expectation, over which the two are indistinguishable.

Use `minAmountIn` to say "too small to be worth filling". It says that directly, where a flat fee only
said it as a side effect of the subtraction underflowing.

Rounding is toward the user (up), because the written value is the solver's delivery **floor** — rounding
down would shave the last unit off what the user receives on every downscaling lane. Ceil rounding also
makes a zero obligation unreachable: with `amountIn >= 1` and `scale >= 1` the quotient is always at least
1, so the contract carries no explicit zero-obligation check.

## Slots and segments

The route is opaque bytes; for a non-EVM destination it is not ABI-encoded at all. Rather than carry the
whole blob plus numeric write offsets, an order carries the literal bytes **around** each amount:

```
route = segments[0] ‖ enc(slots[0]) ‖ segments[1] ‖ … ‖ segments[n]
```

with `segments.length == slots.length + 1`. A mis-stated write position is not expressible, and the same
representation serves an EVM destination and a Borsh one without the contract knowing which it holds.

Each `Slot` is just geometry — `width` in bytes and `littleEndian` — because every slot receives the same
number. A value that does not fit its width reverts; it is never truncated.

### Solana

A Solana route is Borsh, and the amount appears **twice** — once as `route.tokens[0].amount` and again
inside the SPL `transfer_checked` instruction data. Both are 8-byte little-endian u64, so amounts above
`type(uint64).max` are rejected. For the shape that `DepositAddress_USDCTransfer_Solana._encodeRoute`
emits (one token, one call, four account metas):

```
  0  salt               32
 32  deadline            8  u64 LE
 40  portal             32
 72  native_amount       8  u64 LE
 80  tokens.len          4  u32 LE
 84  tokens[0].token    32
116  tokens[0].amount    8  u64 LE   ← slot
124  calls.len           4  u32 LE
128  calls[0].target    32
160  calls[0].data.len   4  u32 LE
164  instrData.len       4  u32 LE
168  0x0c                1            transfer_checked discriminator
169  amount              8  u64 LE   ← slot
177  decimals            1
```

Those offsets hold only for that shape — a second call or a different account list moves the one at 169,
which is exactly why orders carry segments rather than offsets.
`../../test/chain/IntentChainerBorsh.t.sol` pins this by cutting a route the production encoder emitted for one
amount and requiring the chainer to reproduce, byte for byte, what that encoder emits for a different one.

### EVM

An EVM route is `abi.encode(Route)`, and the amount typically appears in `route.tokens[0].amount` and again
inside `calls[k].data` — the `transfer(swapper, amount)` that feeds a destination swap. Both are 32-byte
big-endian words. The SDK builds segments by encoding the route with a sentinel in every runtime position
and splitting on it; `../../test/chain/IntentChainer.t.sol` does exactly that.

## Why it publishes and never funds

`publish` and nothing else.

- **Funding is unnecessary.** `IntentSource._fundToken` returns early once `balanceOf(vault) >= amount`,
  and `_validateWithdraw` accepts `Status.Initial`. A pushed-but-unfunded intent is fully withdrawable by
  the proven claimant. `fund()` buys a status flag and an event.
- **Funding is unsafe from here.** Every funding entry point — `fund`, `fundFor`, `publishAndFund`,
  `publishAndFundFor`, `open`, `openFor` — ends in `Refund.excessNative()`, which forwards the Portal's
  **entire** native balance to `msg.sender`. Reached re-entrantly from inside a route call, `msg.sender` is
  the chainer, so it would silently capture the solver's in-flight ETH. The contract is non-payable and has
  no `receive()` to keep that unreachable.
- **`publish` is what makes intent2 findable.** `IntentPublished` is the only event carrying the route as
  complete bytes plus every `Reward` field. Since the amount did not exist until execution, no off-chain
  party can reconstruct intent2 without it.

Intent2 therefore settles at `Status.Initial`, which is normal and not a sign of under-funding —
`isIntentFunded` reads live vault balances and returns true.

## Why no access control

Route calls reach every contract through the Portal's single shared `Executor`, which any fulfiller of any
intent drives permissionlessly. `msg.sender` proves only that _some_ route call is running, never whose, so
a caller gate would buy nothing.

The authorization anchor is intent1's own hash instead. The entire `Order` — intent2's route bytes, its
`reward.creator`, the fee, the floor — rides inside `intent1.route.calls[k].data`, which is covered by
`keccak256(abi.encode(route))`, which is covered by the `intentHash` that `Inbox` re-derives and checks
before executing anything. A solver cannot alter the order it is executing.

The residual exposure is a balance donated to the contract out-of-band, which the next caller sweeps into
their own intent. The intended flow never leaves a balance at rest.

## What the SDK must get right

Three invariants are not enforceable on-chain:

- **Fresh salt per order.** Intent2's salt is fixed in the committed template, so two orders sharing a salt
  _and_ landing on the same measured amount produce the same intent hash. If that hash has already settled,
  `publish` reverts `IntentAlreadyExists` and unwinds intent1.
- **Route deadline.** `MIN_DEADLINE_BUFFER` guards `reward.deadline`. Intent2's **route** deadline lives
  inside the opaque bytes and cannot be read here at all, so an intent2 whose route deadline has already
  passed publishes and funds successfully, is unfulfillable, and locks the escrow until `reward.deadline` —
  the longer of the two by construction. This is the one deadline with no on-chain backstop on either VM.
- **Deadline headroom.** Intent2's deadlines are absolute and fixed when intent1 is signed, but intent1 may
  be fulfilled any time up to its own route deadline. The contract rejects a reward deadline inside
  `MIN_DEADLINE_BUFFER`, but leaving real headroom is the builder's job. Set intent2's reward deadline
  comfortably beyond intent1's route deadline.
- **Slot and call agreement.** If a route's `tokens[j].amount` and the calldata that moves it are cut as
  separate slots, they receive the same value — but if the template's _calls_ expect a different amount than
  the token leg declares, the difference is left on the shared `Executor`, which has no sweep and is
  claimable by the next fulfiller of any intent. Emit both from one value.

Note the donation row says _any_ token: `order.token` is chosen by the order, and `chain` sweeps that
token's entire balance, so anything mistakenly sent to a widely-known singleton is reachable — not only the
lane's own asset.

## Recovery

| state                                      | who recovers                                                                 | how                                                |
| ------------------------------------------ | ---------------------------------------------------------------------------- | -------------------------------------------------- |
| swap under-delivered below `minAmountIn`   | nobody needs to — intent1 reverts whole                                      | —                                                  |
| amount will not fit a slot's width         | nobody needs to — intent1 reverts whole                                      | —                                                  |
| intent2 published and funded, never solved | `reward.creator`                                                             | `refund()` after `reward.deadline`, permissionless |
| intent2 solved                             | claimant takes `amountIn`; any surplus in the vault goes to `reward.creator` | `withdraw()`, then `refund()`                      |
| any token sent to the chainer              | whoever chains next                                                          | swept into their intent                            |

## Deployment

`scripts/DeployIntentChainer.s.sol`, CREATE3, one per Portal per chain:

```
PRIVATE_KEY=0x... SALT=0x... PORTAL=0x... forge script \
  scripts/DeployIntentChainer.s.sol --rpc-url <RPC_URL> --broadcast --slow
```

CREATE3 derives the address from `(deployer, salt)` alone, so the chainer lands at the same address on every
chain even where the Portal differs — orders name it inside a committed `call.target`, so one address to
hard-code is worth more here than usual. Bump `CHAINER_VERSION` on any constructor or `Order` ABI change:
without a salt bump a new ABI would land on the old address and orders committed against the old shape would
decode into the new one.
