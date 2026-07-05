# PR4 — reward-conservation + chain gates + same-chain fulfillAndSettle

> Hardens the Model C dual-account/runtime from PR3 and makes same-chain a first-class primitive.
> Re-authored onto the reconciled PR3 (minTokens input-floor, no sweep, dual `executeAsOwner`).

## 1. fulfill derives the hash on-chain and takes the full reward

`fulfill` / `fulfillAndProve` now take `(source, destination, route, Reward reward, claimant,
providedAmounts, prover [, sourceChainDomainID, data])` and DERIVE the intent hash on-chain
(`IntentLib.hashIntent(source, destination, keccak(route), keccak(reward))`). The caller-supplied
`intentHash` and the `InvalidHash` mismatch check are gone: a tampered route is simply recorded under its
own derived hash (solver self-harm, not a double-spend). Passing the full `reward` (not just its hash)
authenticates `reward.tokens` so the conservation snapshot below can identify the escrow legs. The
ERC-7683 `originData` becomes `(uint64 source, bytes route, Reward reward)`.

## 2. Reward-conservation postcondition (same-chain escrow protection)

In `Inbox._fulfill`, BEFORE staging any solver input, snapshot the execution Account's balance of every
`reward.tokens` leg (and native) — the reserved escrow `E`. AFTER `account.execute`, require each leg's
balance `>= E`, else revert `RewardEscrowTouched`.

- **Same-chain** (`source == destination` → escrow and execution Account collapse to ONE): this stops a
  malicious keeper-authored runtime from consuming the reward escrow to fund the route. A violation
  reverts the whole fulfill (griefing DoS for the solver, who simulates first — never reward theft).
- **Cross-chain**: the execution Account holds no source escrow, so every snapshot is ~0 and the check is
  a cheap no-op.

Snapshotting BEFORE staging means a reward token that is ALSO a solver-input token is measured
escrow-only, so the runtime legitimately consuming the staged input does not trip conservation.

## 3. block.chainid role gates

- Source-side ops (`onlySourceChain(source)`): `fund` / `fundFor` / `publishAndFund(For)` / `settle` /
  `refund` / `refundTo` / `recoverToken` / `executeAsOwner` revert `WrongSourceChain(current, expected)`
  unless `block.chainid == source`. Each resolves the SOURCE escrow account keyed by `intent.source`, so
  it is only meaningful on the source chain — belt-and-braces on top of the Model C address separation.
- Destination op: `fulfill` reverts `WrongDestinationChain(current, expected)` unless
  `destination == block.chainid`.

## 4. PortalCore.fulfillAndSettle (same-chain, one tx)

New abstract `PortalCore` (shared by `Portal` + `PortalTron`) adds
`fulfillAndSettle(intent, providedAmounts, claimant)` for `source == destination == block.chainid`: it
runs `_fulfill` (execute in the shared Account, enforce reward-conservation, record the local fact) then
`_settle` from that same Account, reading the just-recorded fact — no relay, no cross-chain round-trip.
`settle` is split into an `onlySourceChain` public wrapper + an internal `_settle` reused here. This is
capital-EFFICIENT but NOT the v2 zero-capital flash: reward-conservation forbids the runtime from
consuming the escrow, so the solver supplies the route input capital.

## 5. Destination executeAsOwner is CROSS-CHAIN ONLY

PR3 added `Inbox.executeAsOwner(source, route, rewardHash, runtime, payload)` gated by `route.keeper` for
destination leftover retrieval. PR4 restricts it to cross-chain: it reverts `SourceChainOwnerOnly` when
`source == block.chainid`. Rationale: on this chain the `block.chainid`-keyed Account is (or, same-chain,
collapses with) the SOURCE escrow Account, and this path is reward-blind (only `rewardHash`), so it cannot
run the conservation snapshot or the `AccountLocked` escrow/proof lock. Same-chain leftover retrieval
therefore flows solely through the reward-aware `IntentSource.executeAsOwner` (reward.keeper +
`AccountLocked`). Cross-chain, the destination Account provably holds only unconsumed solver input (a
distinct address from the source escrow), so `route.keeper` may cook it freely.

> This supersedes PR4's original recipient-authorized `rescueDestination` (a token-scoped, reward-excluding
> rescue): under the unopinionated core there is no `recipient`, and the destination cannot see the reward
> to exclude its tokens — which is exactly the isolation property that motivated `route.keeper`. Restricting
> the arbitrary-runtime path to where the account is provably escrow-free is the equivalent safety.

## 6. Size budget

Portal / PortalTron = 22,880 B (< 24,576, headroom 1,696) at `optimizer_runs = 20,000`. PR4's additions
(conservation loop, chain-gate modifiers, PortalCore) pushed the size past the ceiling at 1,000,000, so
the optimizer was lowered to the highest value that keeps comfortable headroom (foundry.toml +
hardhat.config.ts in lockstep).

## 7. Tests

`test/core/SameChainAndGates.t.sol` (19 tests): reward-conservation (malicious drain reverts, honest
passes); source/destination chain gates on every gated op; `fulfillAndSettle` (happy path,
solver-supplies-capital, `NotSameChain`); destination `executeAsOwner` (cross-chain keeper recovers
leftover, same-chain reverts `SourceChainOwnerOnly`, non-keeper reverts `NotAccountKeeper`); and the
role-collision matrix. Full suite green: forge 608, hardhat 112, jest 42.
