# PR1 — Move fulfillment storage into the prover; `fulfill` names its policy

> Move the **destination fulfillment storage** out of `Inbox` and into the prover, and move the
> **proof-message build + dispatch** with it. To fulfill, the solver now **names the prover** it
> records into. This is the first step of the v3 "the prover is the policy engine on both chains"
> redesign. It keeps `main`'s existing model in every other respect: the `(intentHash, claimant)`
> EVM-address fact shape, the `keccak256(destination, routeHash, rewardHash)` intent hash, and the
> reward model are all unchanged. The Prover→Policy rename and the transport/policy relay split are
> **deferred to PR2**.

## 1. Why

On `main`, the `Inbox` owned a `mapping(bytes32 => bytes32) public claimants` — the record of "which
claimant fulfilled which intent on this chain" — and `Inbox.prove` encoded that record into the wire
message it handed to the prover. That put the destination fulfillment fact in the transport-agnostic
`Inbox` rather than in the contract a creator actually commits to (`reward.prover`).

Moving the fulfillment fact into the prover makes the prover the single owner of the fact on both
chains: it records the fulfillment on the destination, builds and dispatches the proof from its own
store, and (on the source) receives and stores the proven fact. The `Inbox` shrinks to
hash-verification + execution and is now genuinely policy-agnostic — it just hands the fulfillment
fact to the named prover. This is the seam every later policy (streaming, vesting, milestone, …)
builds on: re-fulfillability becomes the prover's storage policy, not an `Inbox` flag. PR1 only moves
the storage and dispatch; it does not add any new policy.

## 2. The new `fulfill(..., prover)` convention — "name your policy"

`Inbox.fulfill` and the internal `_fulfill` gained a trailing `address prover` parameter:

```solidity
function fulfill(
    bytes32 intentHash,
    Route memory route,
    bytes32 rewardHash,
    bytes32 claimant,
    address prover            // NEW: the policy to record the fulfillment into
) external payable returns (bytes[] memory);
```

`_fulfill` re-derives the intent hash, checks the portal/hash/deadline/zero-claimant exactly as before,
then instead of writing a local `claimants` slot it calls:

```solidity
IProver(prover).recordFulfillment(intentHash, CHAIN_ID, claimant);
```

`fulfillAndProve(..., prover, sourceChainDomainID, data)` (unchanged signature — it already carried the
prover) records into `prover`, then forwards to `prove`. `Inbox.prove` is now a thin forwarder:

```solidity
function prove(address prover, uint64 sourceChainDomainID, bytes32[] intentHashes, bytes data) public payable {
    IProver(prover).prove{value: address(this).balance}(msg.sender, sourceChainDomainID, intentHashes, data);
}
```

The old `Inbox.prove` encoding loop (8-byte chain-id header + `(intentHash, claimant)` pairs read from
`claimants`) and the destination-side `IntentProven` emission moved into the prover (see §4).

## 3. `recordFulfillment` — only-Portal, one-shot

Added to `IProver` and implemented in `BaseProver` (and, independently, in `LocalProver`):

```solidity
function recordFulfillment(bytes32 intentHash, uint64 destination, bytes32 claimant) external;
```

- **only-Portal**: reverts `NotPortal(msg.sender)` unless called by the local Portal/Inbox. The Portal
  is the trusted destination fulfillment source — it re-derived the intent hash and executed the route.
- **one-shot**: reverts `IntentAlreadyFulfilled(intentHash)` if the intent was already recorded. This is
  where the "already fulfilled" gate now lives — it moved out of `Inbox._fulfill` (which used to check
  `claimants[intentHash] != 0`) into the prover. A second fulfillment of the same intent under the same
  prover reverts. Atomic isolation is now structural in the prover's one-slot store.
- The `destination` argument is the local chain id supplied by the Portal; it is implied by the prover's
  own `CHAIN_ID` at proof-build time, so PR1 does not store it (the one-slot store is `intentHash →
  claimant`). It is part of the signature for the later policies that will use it.

`BaseProver` gained an immutable `CHAIN_ID` (set in the constructor, `ChainIdTooLarge` if
`block.chainid` overflows `uint64`) and a `mapping(bytes32 => bytes32) internal _destFulfillment`, plus a
public `destFulfillment(bytes32) → bytes32` view getter so the destination fulfillment fact is readable
on-chain (used by indexers/solvers and by the tests that assert "recorded on the destination but skipped
during proving because the claimant was non-EVM").

## 4. The prover builds and dispatches its own proof message

`IProver.prove`'s third parameter changed from `bytes calldata encodedProofs` to
`bytes32[] calldata intentHashes`. The prover now builds the wire message itself from its own store via
`BaseProver._buildProofMessage(intentHashes)`, which replicates `main`'s `Inbox.prove` encoding
**exactly** — an 8-byte big-endian `CHAIN_ID` header followed by, per hash, a 64-byte
`(intentHash, claimant)` pair read from `_destFulfillment` (reverting `IntentNotFulfilled(intentHash)`
for an unrecorded hash). Because the encoding is byte-identical, every downstream consumer (the
source-side `_processIntentProofs`, the Polymer `validate` path, the loopback test mocks) sees exactly
what it saw on `main`.

Per transport:

- **`MessageBridgeProver`** (Hyper / Meta / LayerZero / CCIP): `prove` builds the message, then runs the
  unchanged fee / dispatch / refund logic. `_dispatchMessage` and `fetchFee` now take
  `bytes memory encodedProofs` instead of `bytes calldata` (the message is built in memory); the concrete
  provers only needed that location change — their bridge logic is untouched.
- **`PolymerProver`**: `prove` builds the message and emits `IntentFulfilledFromSource` (its dispatch is
  an event its relayer proves on the source — the emitted event *is* the proof). Its source-side
  `validate`/`validateBatch` path is unchanged.
- **`LocalProver`** (same-chain): `prove` is a no-op (same-chain needs no dispatch), now matching the new
  `(address, uint64, bytes32[], bytes)` signature.

The destination-side `IntentProven` emission that `Inbox.prove` used to make (the 2-arg
`IInbox.IntentProven(intentHash, claimant)`) is **not** re-emitted from the prover — see §7. The
meaningful source-side `IProver.IntentProven(intentHash, claimant, destination)` (emitted by
`_processIntentProofs` when the proven fact is received) is preserved unchanged, as is the destination
`IInbox.IntentFulfilled` emitted by `_fulfill`.

## 5. Per-policy fulfillment isolation — naming the wrong prover is solver self-harm

Fulfillment is now recorded per prover. Settlement on the source reads the fulfillment through
`reward.prover` — the prover the *creator* committed to in the intent (`IntentSource.withdraw` /
`_validateRefund` call `IProver(reward.prover).provenIntents(...)`, unchanged). So:

- If a solver fulfills naming the **correct** prover (`reward.prover`), settlement reads its record and
  pays out — the normal path.
- If a solver fulfills naming the **wrong** prover, the fulfillment is recorded against a prover that
  settlement never consults. The solver executed the route and delivered value but cannot be paid. This
  is **solver self-harm only** — it cannot strand the creator's reward (the reward stays escrowed and is
  refundable after the deadline) and cannot block the correct prover (a different store). The `Inbox`
  does not need to validate `prover == reward.prover`; the economics do.

## 6. Same-chain reads via LocalProver's own store

`LocalProver` does not extend `BaseProver`; it keeps its own `mapping(bytes32 => bytes32)
_destFulfillment` + `recordFulfillment` (only-Portal, one-shot). Its `provenIntents` now reads that store
instead of `Inbox(_PORTAL).claimants(...)`, preserving all three behaviors from `main`:

- **Griefing vector 1** (someone fulfills naming LocalProver as the *claimant*): the recorded claimant
  equals LocalProver's own address ⇒ treat as unfulfilled (`ProofData(0, 0)`) so refunds remain reachable.
- **Griefing vector 2** (a non-EVM `bytes32` claimant): fails `AddressConverter.isValidAddress` ⇒ treat as
  unfulfilled.
- **flash-in-progress**: during `flashFulfill`, before the fulfillment is recorded, `provenIntents`
  returns LocalProver as the claimant (gated by `_flashFulfillInProgress == intentHash`) so the vault
  withdrawal succeeds. `flashFulfill` now calls `_PORTAL.fulfill(intentHash, route, rewardHash, claimant,
  address(this))` — it names itself as the prover, so the inner fulfill records the actual solver into
  LocalProver's store.

A same-chain intent therefore needs no relay, no bridge, and no fee: the fulfillment recorded on the
destination *is* the proof the source reads (both are the same chain, same contract).

## 7. What is intentionally NOT preserved (and why)

`Inbox.prove` on `main` emitted a destination-side `IInbox.IntentProven(bytes32 intentHash, bytes32
claimant)` per hash. PR1 does **not** re-emit it. Re-emitting it from the prover would put a second event
named `IntentProven` into every prover's ABI (the prover already declares the 3-arg
`IProver.IntentProven`), making `.getEvent('IntentProven')` ambiguous and breaking the TypeScript event
matchers. No test asserts the 2-arg destination emission, and the two events that carry the real signal —
`IInbox.IntentFulfilled` on the destination and `IProver.IntentProven` on the source — are both
preserved. The `IInbox.IntentProven` / `IntentNotFulfilled` / `IntentAlreadyFulfilled` declarations are
kept in `IInbox` (harmless; the Portal ABI is unchanged) even though `Inbox` no longer emits/reverts them
directly.

## 8. Also in this PR

- **File move**: `contracts/prover/LocalProverTron.sol → contracts/tron/LocalProverTron.sol` (import to
  `LocalProver` updated to `../prover/LocalProver.sol`; `../libs/TronTransfer.sol` unchanged; 0x41/TRC20
  parity preserved).
- **Tests**: every `fulfill(...)` caller now passes a prover; assertions on `Inbox.claimants(hash)` now
  read `prover.destFulfillment(hash)` (or, for same-chain, `LocalProver.provenIntents(hash)`); the
  "already fulfilled" revert is now expected from the prover's `recordFulfillment`. The prover unit tests
  record the fulfillment (as the Portal) before calling `prove`, since `prove` builds from the store. The
  `TestProver`/`TestMessageBridgeProver` mocks gained a `receiveProofs` shim so the proof-reception tests
  (which used to drive reception through the old `prove`) keep exercising the unchanged
  `_processIntentProofs`.

## 9. Deferred to PR2

- **Prover → Policy rename** and the `IPolicyProver` surface.
- **Transport / policy split**: `PolicyProver` (fact store + release schedule) vs `RelayBase` (transport +
  cross-chain-sender whitelist), and the hash-only `(intentHash, fulfillmentHash)` fact model.
- Reward legs / `minTokensOut` / `fulfillmentHash` preimage.
