# PR9 — Protocol Versioning (permanent PortalProxy + versioned implementations)

## Goal

Let the protocol ship new Portal behaviour **without ever changing the address that intents and
per-intent Accounts are anchored to**, and give the protocol owner a narrowly-scoped way to sweep funds
that get stuck under an old implementation once it is retired.

Three moving parts:

1. **`Intent.protocolVersion`** — a new creator-declared `uint32`, the FIRST field of `Intent`, hashed into
   the intent hash. It selects which registered implementation serves the intent and pins the intent to that
   implementation for its whole lifetime.
2. **`PortalProxy`** — the new PERMANENT, stable-address contract. It holds a write-once
   `version → implementation` registry and `delegatecall`s each call into the implementation for the call's
   version. This is what everything (solvers, keepers, per-intent Accounts, downstream policies) trusts
   forever.
3. **Deployer sweep** — once an implementation version is `VERSION_EXPIRY` (365 days) old, the protocol owner
   becomes an *alternate authority* on the EXISTING, already-hardened `executeAsOwner` escrow/proof lock — it
   can sweep an account whose intent is independently dead, and nothing more.

## The proxy / implementation split

`Portal` and `PortalTron` used to be the directly-deployed contracts. They are now **implementation**
contracts that only ever run via `delegatecall` from the `PortalProxy`. The deploy script deploys the proxy
as the canonical "Portal" address (`cfg.salt`), deploys the implementation at a derived salt, and calls
`registerVersion(1, implementation)`. Every downstream contract (policies, deposit factories) references the
**proxy** address.

### Why account addresses stay stable across implementation versions

A per-intent Account is an ERC-1167 clone deployed with CREATE2. Its address is
`keccak(0xff, deployer, salt, keccak(cloneCreationCode))` where:

- `deployer` is `address(this)` **of the code doing the CREATE2** (see `Clones.predict`/`Clones.clone`).
  Because `delegatecall` preserves `address(this)`, when the implementation runs behind the proxy
  `address(this)` is the **proxy** — so every Account is deployed and predicted against the proxy's stable
  address, forever, regardless of which implementation version handled the call.
- `cloneCreationCode` embeds the **Account implementation** address (`ACCOUNT_IMPLEMENTATION`) and the
  CREATE2 prefix. These are immutables of the Portal implementation. For the address to be identical across
  Portal versions, **every version must be deployed with the SAME Account implementation + prefix**.

To make this a structural guarantee rather than a deploy-time convention, the **Account implementation is a
single shared contract**: it is deployed once (bound to the proxy — see below) and passed into every Portal
version's constructor as the clone template. The deploy script does exactly this; a hypothetical version 2 is
`new Portal(sameAccountImplementation)`, so it derives byte-identical account addresses.

`test/core/ProtocolVersioning.t.sol::test_accountAddressStableAcrossImplementationVersions` proves it:
registering a second implementation (built on the same shared Account implementation) and computing
`accountAddress(intentHash, chainId)` before and after registration returns the identical address.

### The `Account` must trust the PROXY, not an implementation

`Account.onlyPortal` authorizes a single `portal` address. Since every account call originates from the
implementation running *as the proxy* (`msg.sender` seen by the Account is the proxy), the Account's `portal`
must be the **proxy**. The shared Account implementation is therefore constructed with the proxy address:
`new Account(proxyAddress)`. This is why the Account implementation is deployed *after* the proxy (the proxy
address does not depend on any implementation, only on the owner + salt, so there is no cycle).

### Storage safety under delegatecall

The implementation executes in the proxy's storage. To avoid any collision:

- The implementation's only mutable storage is `IntentSource.rewardStatuses` (slot 0). This is *intended* to
  live in proxy storage — the reward lifecycle is shared across versions.
- The proxy keeps its **version registry** in ERC-7201 **namespaced** storage
  (`eco.portal.proxy.registry`), a keccak-derived high slot that cannot collide with the implementation's
  sequential slots.
- The proxy's **owner is immutable** (in code, not storage), matching this codebase's immutable-trust-anchor
  ethos (it uses immutable whitelists, not OpenZeppelin `Ownable`). No storage, no collision.
- `OriginSettler.GASLESS_CROSSCHAIN_ORDER_TYPEHASH` was a mutable public state variable; it is now
  `constant` so it lives in code and reads correctly under delegatecall (a storage state variable would read
  the proxy's unwritten slot). OpenZeppelin `EIP712` uses immutables and rebuilds the domain separator when
  `address(this) != cachedThis`, so the domain separator correctly reflects the proxy address.

## Dispatch

Most Portal entry points take `protocolVersion` as an explicit **leading `uint32` scalar** — this is forced
by the design: the route stays opaque `bytes` at the source (cross-VM compatibility), so on the
`fund`/`fundFor`/`settle`/`refund`/`recoverToken`/stream paths there is no decoded struct to read the version
from. It is threaded exactly like `source`/`destination` already are. `IntentLib.hashIntent` gains a leading
`protocolVersion`, and `intentHash = keccak256(abi.encodePacked(protocolVersion, source, destination,
routeHash, rewardHash))`.

The proxy dispatches as follows:

- **`fallback()`** handles every entry point whose first ABI argument is `uint32 protocolVersion`: it reads
  the version straight from `calldata[4:36]` and `delegatecall`s the resolved implementation. No per-function
  code. A selector-only call (`4 <= len < 36`, a no-argument view like `domainSeparatorV4`) is
  version-agnostic and routes to the latest implementation; `< 4` bytes reverts.
- **Typed forwarders** exist only for the exceptions:
  - Entry points taking a full `Intent` (`publish(Intent)`, `publishAndFund(Intent,bool)`,
    `publishAndFundFor`, `intentAccountAddress(Intent)`, `isIntentFunded(Intent)`, `getIntentHash(Intent)`,
    source-side `executeAsOwner(Intent,...)`, `fulfillAndSettle`) — the version is read from
    `intent.protocolVersion` and the intent is served by that version's implementation (pinning).
  - Version-agnostic helpers (`getRewardStatus`, `accountAddress`, `version`, `prove`) and the ERC-7683
    adapter surface (`open`/`openFor`/`resolve`/`resolveFor`/`fill`) — routed to the **latest**
    implementation. These either only read shared proxy storage / derive an address that is identical across
    versions, or carry the pinned version inside their order/originData that the implementation validates and
    hashes with.

Each forwarder is a one-liner over an internal `_delegate(impl)` that copies calldata, `delegatecall`s, and
bubbles the raw return/revert verbatim. Resolving an **unregistered** version reverts
`UnknownProtocolVersion`; an **expired but registered** version still resolves (existing intents must stay
settleable/refundable/sweepable forever — only `publish` additionally rejects an expired version for NEW
intents).

## The version registry

`struct VersionInfo { address implementation; uint64 registeredAt; }`,
`mapping(uint32 => VersionInfo)` in namespaced storage. `registerVersion(version, implementation)` is
owner-only and **write-once**: re-registering a version reverts `VersionAlreadyRegistered`, and
`implementation == address(0)` reverts `ZeroImplementation`. There is no removal and no re-pointing — a
version's binding is immutable once set, matching the codebase's `Whitelist` immutability ethos (repointing a
version that live intents reference would be a rug vector). A `latestVersion` counter tracks the highest
registered version for the version-agnostic forwarders.

## `publish` validation

`publish` calls `requireValidProtocolVersion(address(this), protocolVersion)` (a free function reading the
proxy registry via `address(this)` under delegatecall): it reverts `UnknownProtocolVersion` if the version is
unregistered and `ProtocolVersionExpired` if `block.timestamp >= registeredAt + VERSION_EXPIRY`. A new intent
can therefore never be created already-sweepable.

## Deployer sweep — alternate authority on the existing lock

The sweep is **not a new function and not a new check**. It is a second authorized caller on the EXISTING
`executeAsOwner`, on both the source and destination sides.

Source side (`IntentSource.executeAsOwner`, keyed by `intent.protocolVersion`):

```solidity
bool isKeeper = msg.sender == intent.reward.keeper;
bool isDeployerSweep = msg.sender == IPortalProxy(address(this)).owner()
    && isProtocolVersionExpired(address(this), intent.protocolVersion);
if (!isKeeper && !isDeployerSweep) revert NotAccountOwner(msg.sender);
// ... UNCHANGED AccountLocked escrow/proof lock runs identically below ...
```

Destination side (`Inbox.executeAsOwner`): the same OR-branch is added to the existing `route.keeper` check,
and the existing **cross-chain-only** restriction (`SourceChainOwnerOnly` when `source == block.chainid`)
still applies to BOTH authorities — the same-chain collapse safety reasoning is caller-independent (a
same-chain intent's leftover retrieval must always go through the source-side, escrow-aware path).

### Why this is the safe minimal design — a two-condition gate

The deployer sweep is authorized only when **both**:

1. the intent's protocol version is **expired** (`registeredAt + 365 days` has passed), AND
2. the account is **independently dead** — which is exactly what the existing `AccountLocked` lock already
   enforces: `executeAsOwner` reverts `AccountLocked` in any non-terminal status while the reward still has
   live legs and is before its deadline, or while a valid destination proof exists (a solver may be owed).

Condition (2) falls out **for free** from code that was written and hardened in an earlier PR (the PR3
`executeAsOwner` critical fix), so the deployer path rides the SAME safety rail the keeper does. Expiry ALONE
is never sufficient: after expiry the owner still cannot touch an account that has live reward legs before the
deadline or a valid unsettled proof. No existing invariant (the lock, the cross-chain-only restriction) is
weakened to make the deployer path work.

`test/core/ProtocolVersioning.t.sol` proves, for both sides:
(a) before expiry the owner cannot sweep (only the keeper can) — reverts `NotAccountOwner` /
`NotAccountKeeper`;
(b) after expiry the owner can sweep an independently-dead account (empty-reward, or past-deadline with no
live legs and no proof);
(c) after expiry the owner is STILL blocked by `AccountLocked` if the account has live reward legs before the
deadline or a valid unsettled proof — expiry alone is never enough;
(d) the destination-side deployer sweep is additionally rejected same-chain (`SourceChainOwnerOnly`), like the
keeper.

## Size budget

`optimizer_runs` lowered from 1000 to 400 (foundry.toml + hardhat.config.ts in lockstep): the Portal
implementation grew with the per-entry-point `protocolVersion` parameter, the `publish`/sweep version reads,
and the deployer-sweep branch. At 400 runs the implementation is comfortably under the 24,576 B EIP-170 limit,
and `PortalProxy` is a small (~3 KB) standalone contract with its own budget.

## Deferred / out of scope

- **Settable `VERSION_EXPIRY`.** It is a file-level `constant` (365 days), not an owner-settable parameter —
  deliberately, matching the immutable-trust-anchor ethos. Making it settable would add a mutable trust knob;
  bumping the constant in a new implementation version is the intended path if the horizon ever needs to
  change.
- **ERC-7683 order version pinning at the proxy.** The ERC-7683 adapter surface routes to the latest
  implementation; the order's declared `protocolVersion` still travels in `OrderData` → `originData` and is
  validated (`publish`) and hashed with by the implementation, so the created/filled intent is correctly
  pinned in its hash. Pinning the *executing implementation* of `open`/`fill` to the order's declared version
  (rather than latest) is a possible future refinement if implementation versions ever diverge in
  open/publish behaviour.
- **Owner transfer.** The proxy owner is immutable. Rotating the protocol owner would require a new proxy
  (and is out of scope); it is intentionally not a mutable knob.
