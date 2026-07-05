# PR10 — ERC-7683 adapter split (lean, delegatecall-direct)

**Branch:** `v3/10-erc7683-adapter-split` (base `v3/09-protocol-versioning`)

## Goal

Reclaim Portal bytecode headroom by moving the ERC-7683 surface
(`open`/`openFor`/`resolve`/`resolveFor`/`fill`, plus the EIP-712 helpers) OUT of the core Portal
implementation into a separate contract that the Portal falls back to. PR9 had eroded `optimizer_runs`
all the way to **400** (main uses 1,000,000) because the combined Portal was bytecode-bound. Splitting the
Settlers off restores **`optimizer_runs = 1,000,000`**.

## Why the first attempt was rejected (and the real bug it hid)

The first attempt made `ERC7683Implementation` inherit `IntentSource + Inbox + OriginSettler +
DestinationSettler + Semver` — i.e. it re-embedded ALL of IntentSource+Inbox's logic a SECOND time just to
satisfy the Settlers' abstract hooks. Result: `ERC7683Implementation` weighed **23,892 B** and became the
new binding contract at only 684 B headroom — *worse* than the problem it set out to solve, and it capped
`optimizer_runs` at 1000.

The naive fix ("just have the adapter call the proxy's own public interface") is not merely wasteful — for
the fulfill path it is **a real funds bug**. `Inbox._fulfill` pulls the solver's ERC20 input with:

```solidity
IERC20(token).safeTransferFrom(msg.sender, account, provided); // contracts/Inbox.sol:361
```

`msg.sender` is **hardcoded** — there is no explicit-provider parameter (unlike `funder` on the publish
path). A plain external self-`CALL` from the adapter back into the proxy resets `msg.sender` to the proxy's
own address, so the re-entered `_fulfill` would try to pull the solver's tokens **from the proxy** (which
holds none) — silently breaking every ERC-7683 `fill()`. (Verified by reading `Inbox.sol` directly.)

## The corrected design

`ERC7683Implementation` (`contracts/ERC7683/ERC7683Implementation.sol`) inherits **ONLY**
`OriginSettler, DestinationSettler` — NOT `IntentSource`, NOT `Inbox`, NOT `AccountDeployer`, NOT `Semver`.
It carries essentially zero business logic. Its two abstract Settler hooks resolve the pinned Portal
implementation for the call's `protocolVersion` and **`delegatecall` DIRECTLY into it**:

1. `_resolveImplementation(pv)` — a harmless VIEW self-read `IPortalProxy(address(this)).versions(pv)`.
   `address(this)` IS the proxy here (the adapter is reached two delegatecalls deep from the original
   external call), so this reads the proxy's own registry. Reverts `UnknownProtocolVersion` if unset.
2. `delegatecall` that resolved implementation, invoking its REAL `publishAndFund(For)` / `fulfillAndProve`.
   A `delegatecall` (unlike a plain `CALL`) **never rebases `msg.sender` or `address(this)`** — both are
   preserved from the enclosing frame — so the core Portal logic runs against the proxy's storage with the
   ORIGINAL caller as `msg.sender`. This is exactly what makes it correct where a self-CALL is broken.

### Call path

```
open/openFor/resolve/resolveFor/fill  (external)
   -> PortalProxy forwarder            (delegatecall #1: address(this)=proxy, msg.sender=caller)
   -> Portal (lean impl)               [selector not found]
   -> PortalCore.fallback()            (delegatecall #2: still proxy + caller)
   -> ERC7683Implementation.<fn>
        -> _resolveImplementation(pv)  (view self-read of the proxy registry)
        -> delegatecall pinned impl    (delegatecall #3: STILL proxy + caller)
           -> Portal.publishAndFund(For) / Inbox.fulfillAndProve  (writes proxy storage, pulls from caller)
```

`PortalProxy` needed **no changes** — its existing `open/openFor/resolve/resolveFor/fill` forwarders already
dispatch to `_latestImplementation()` (the lean Portal), whose new `fallback` relays onward.

### Detaching the Settlers

- `IntentSource is AccountDeployer, IIntentSource` (was `..., OriginSettler, ...`). Its `_publishAndFund`
  is now a plain internal helper (no `override`) — nothing abstract requires the override relationship.
- `Inbox is AccountDeployer, IInbox` (was `..., DestinationSettler, ...`). `fulfillAndProve` stays a real,
  directly-callable function (`override(IInbox)`).
- `PortalCore` gains an immutable `ERC7683_IMPLEMENTATION` (2nd ctor arg after `accountImplementation`) and
  a `fallback() external payable` that delegatecalls it. The fallback uses `assembly ("memory-safe")` —
  REQUIRED, or via-IR drops the memory guard and the inherited `_fulfill` overflows the stack at compile.
- `OriginSettler`'s constructor drops its `EIP712("EcoPortal","1")` args (else "base constructor arguments
  given twice" once `ERC7683Implementation` supplies them). `ERC7683Implementation` has the sole
  `constructor() EIP712("EcoPortal", "1") {}`.

### `abi.encodeCall` overload bridging

`IIntentSource.publishAndFund`/`publishAndFundFor` are overloaded (struct + decomposed forms), and
`abi.encodeCall`/`.selector` cannot pick between overloads by name. A tiny dedicated NON-overloaded
interface `IPortalPublishAndFund` (declared in the adapter file, byte-identical decomposed signatures →
identical selectors) lets `abi.encodeCall` reference each unambiguously. `IInbox.fulfillAndProve` is not
overloaded, so `abi.encodeCall(IInbox.fulfillAndProve, (...))` is used directly.

## Funding path — one deliberate behaviour change (needs sign-off)

The pre-split `open`/`openFor` funded through `IntentSource._publishAndFund` -> `_fundIntent`, which pulls
each ERC20 leg via **the PROXY's allowance** (`safeTransferFrom(funder, account)` executed by the Portal).
There is **no public function** that pulls from an ARBITRARY funder via proxy allowance — and there must not
be, because that would let anyone drain any address that has approved the proxy. That path is only safe when
`funder == msg.sender` or the funder is signature-authenticated (openFor). The only public arbitrary-funder
entry point, `publishAndFundFor`, deliberately pulls via **the per-intent Account's allowance** instead
(safe: the funder must have approved that specific Account).

So the adapter's `_publishAndFund` branches on `funder == msg.sender`:

- **`open` (funder == msg.sender)** -> delegatecall `publishAndFund` (proxy-allowance). **Behaviour is
  preserved byte-for-byte** — existing "approve the proxy, then open" integrations and tests are unchanged.
- **`openFor` with a distinct signed user (funder != msg.sender)** -> delegatecall `publishAndFundFor`
  (account-allowance, empty permit). This is the ONE unavoidable change: the signed user must approve the
  (deterministic, pre-computable via `intentAccountAddress`) intent Account rather than the proxy. It cannot
  be avoided in any lean design without re-introducing the unauthenticated theft vector or re-inheriting
  IntentSource.

Only `test/OriginSettler.spec.ts`'s `openFor` test needed updating (approve the Account); every `open` test
is unchanged. **If a uniform account-allowance policy is preferred instead** (route BOTH paths through
`publishAndFundFor`), drop the `funder == msg.sender` branch and update the `open` tests too — a small delta.

## Storage-layout re-verification

`forge inspect ... storage-layout` (run on all four contracts):

| Contract | `rewardStatuses` slot | EIP712 fallback slots |
|---|---|---|
| `Portal` | 0 | — (EIP712 detached from the lean Portal) |
| `PortalTron` | 0 | — |
| `ERC7683Implementation` | *(not declared)* | `_nameFallback`=0, `_versionFallback`=1 |

Why the risk that sank the first attempt **dissolves** here:

- In the first attempt BOTH Portal and the adapter declared `rewardStatuses`, so their slots had to match
  exactly (which forced EIP712 to sit at identical positions in both) — a fragile cross-contract invariant.
- In this design **only the Portal declares `rewardStatuses`** (the adapter never inherits IntentSource).
  All `rewardStatuses` reads/writes execute inside the Portal's own bytecode (via the final delegatecall),
  which computes its own consistent slot 0. The adapter never touches `rewardStatuses`.
- The adapter's only own slots (0/1) are OZ EIP712's fallback strings, which are **never read or written at
  runtime**: "EcoPortal"/"1" are short-string immutables in code, and `_buildDomainSeparator` reads the
  immutable hashes, not storage. So the adapter's bytecode never writes proxy slot 0/1 — it cannot corrupt
  Portal's `rewardStatuses`. (Same proxy-safe EIP712 mechanism PR9 already relied on.)

Proven at runtime too — see the cross-boundary tests below (state written via one path, read via the other).

## TRON variant — not needed

The lean `ERC7683Implementation` has **no** account-derivation logic: no `AccountDeployer`, no CREATE2, no
0x41-vs-0xff prefix, no Account cloning, no `_transferToken`. Those are the only TRON-specific concerns, and
they all live in `PortalTron`/`AccountTron` (which the adapter reaches via the version-resolved delegatecall,
unchanged). So **one** `ERC7683Implementation` serves BOTH the EVM `Portal` and the TRON `PortalTron` — no
`ERC7683ImplementationTron`. The deploy script wires the same adapter into both Portal ctors.

## Sizes and optimizer_runs

`optimizer_runs = 1,000,000` (foundry.toml + hardhat.config.ts in lockstep) — restored from PR9's 400.

| Contract | runtime (B) | headroom to 24,576 |
|---|---|---|
| `Portal` | 23,564 | 1,012 |
| `PortalTron` | 23,564 | 1,012 |
| `ERC7683Implementation` | 10,105 | 14,471 |
| `PortalProxy` | 3,723 | 20,853 |

The lean adapter is 10,105 B (vs the rejected attempt's 23,892 B). Portal dropped from PR9's 23,469 B to
18,000 B *at 400 runs*; the reclaimed ~5.5 KB is what lets 1,000,000 runs fit (23,564 B). Headroom is 1,012 B
— comparable to PR9's own 1,107 B, and it is the highest standard optimizer value. A lower value buys more
margin if desired, but 1,000,000 is the highest that fits all contracts.

## Gates

- `forge build` — 0 errors.
- `forge test` — **673 passed / 0 failed** (669 baseline + 4 new).
- `npx hardhat test` — **112 passed**.
- `node_modules/.bin/jest` — **46 passed**.

## Tests (`test/core/ERC7683AdapterSplit.t.sol`)

1. `test_open2hop_write_coreRead_funded` — `open()` (2-hop) funds; core `getRewardStatus` (1-hop) reads
   `Funded` and the escrow lands at the core-derived Account. (7683 write → core read.)
2. `test_coreWrite_open2hop_readsTerminalStatus` — core `publishAndFund`+`refund` (1-hop) → `Refunded`;
   a subsequent `open()` (2-hop) reverts `IntentAlreadyExists`. (core write → 7683 read.)
3. `test_open2hop_fund_coreSettle_roundtrip` — `open()` funds (2-hop), core `settle` (1-hop) pays the
   claimant out of that escrow and marks `Withdrawn`. (full round trip over one shared storage/escrow.)
4. `test_fill2hop_pullsSolverOwnTokens_notProxy` — **the msg.sender-preservation proof**: a distinct solver
   with its own balance + a proxy approval calls `fill()` through the 2-hop path; its OWN tokens are pulled
   (balance drops by the input), the proxy's balance stays 0, and the call does not revert. This is the test
   a plain self-CALL design would have failed.
