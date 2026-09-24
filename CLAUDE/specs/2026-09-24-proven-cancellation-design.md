# Proven Cancellation — Design

- **Status:** approved design, not yet implemented
- **Date:** 2026-09-24
- **Repos:** `eco-routes` (EVM Portal + provers) and `eco-routes-svm` (SVM Portal program). This file is the
  single source of truth; `eco-routes-svm/docs/superpowers/specs/2026-09-24-proven-cancellation-design.md`
  points here.
- **Product spec:** Notion — "Permissionless refunds with proven cancellation" (post-meeting hybrid revision).
- **Explainer:** https://claude.ai/artifact/2ShDwF7D1ArEMdBk8BQSmn

## 1. Goal

Today a creator can only reclaim an unfulfilled intent's reward after `reward.deadline`. This design adds a
**fast path**: once `route.deadline` has passed on the destination, anyone may **cancel** the intent there; the
cancellation is proven back to the source through the existing provers, and the source Portal then allows
`refund` immediately. `reward.deadline` stays as the **liveness fallback** for when a proof cannot be relayed.

Target timeline (product target, not a guarantee): `route.deadline` ≈ 5 min after publish, cancel + prove + refund
within minutes after it, with `reward.deadline` long (e.g. 7 days; duration and enforcement remain open product
questions, not decided here).

### Non-goals

- No change to the timeout fallback semantics. The accepted residual solver loss (a timeout refund of a fulfilled
  intent whose proof never arrived) remains accepted.
- No activation for in-flight / legacy intents: the fast path exists only on the new deployment (§8).
- No user self-attestation of any outcome. Only the destination Portal's recorded state, carried by a whitelisted
  prover, can prove a cancellation.
- Off-chain consumers (solver-v2, refund service, routes-ts, indexers) are follow-ups (§10).

## 2. Decisions

| # | Decision | Notes |
|---|---|---|
| D1 | Carry "cancelled" as a **sentinel claimant** in the existing `(intentHash, claimant)` payload | Wire format unchanged on every prover and both VMs. Rejected: per-pair outcome byte (breaks every decoder), versioned header (no version byte exists). |
| D2 | `CANCELLED = keccak256("eco.portal.intent.cancelled")` (32 bytes, identical on both VMs) | Upper 12 bytes non-zero → never a valid EVM address; hash preimage → no Solana private key. |
| D3 | Destination stores the sentinel in its **existing fulfillment record** (`claimants[h]` on EVM, the `FulfillMarker` PDA on SVM) | `fulfill`'s "already fulfilled" check and `prove`'s payload build then cover cancellation with no new branches. |
| D4 | **EVM source:** `ProofData` gains a trailing `Outcome outcome`; a Cancelled proof stores `claimant = address(0)` | Fail-safe: any reader unaware of cancellation (old `IntentSource` pointed at a new prover, third-party integrators) sees "unproven" → timeout, never a payout. ABI-additive: old callers decode the first two words. |
| D5 | **SVM source:** `Proof` layout **unchanged**; a proven cancellation is `Proof { destination, claimant: CANCELLED }` | SVM provers store claimants verbatim → zero prover changes. Old-portal/new-prover mixing is already unrecoverable on SVM (PDA-pinned `close_proof`), so an outcome field buys nothing. |
| D6 | SVM `close_fulfill_marker` leaves a **tombstone** instead of deleting the marker | Otherwise a closed marker is indistinguishable from "never fulfilled" and `cancel` could succeed on a fulfilled intent. |
| D7 | Conflicting outcomes: **first recorded wins**, per prover; `AggregatorProver` resolves by member priority | Deliberate deviation from the Notion spec's "explicit conflict policy" wording, decided 2026-09-24. Conflicts require a compromised prover/bridge (the destination makes the outcomes mutually exclusive). |
| D8 | Release as a **minor** version (`feat:` commits, no `BREAKING CHANGE`) | Decided 2026-09-24. Justified by D4 being ABI-additive. |

## 3. Protocol

### 3.1 Destination record (both VMs)

The per-intent fulfillment record is a three-state cell, written at most once:

```
            fulfill (now ≤ route.deadline)
  EMPTY ──────────────────────────────────▶ claimant   (FULFILLED)
    │
    └──────────────────────────────────────▶ CANCELLED  (CANCELLED)
            cancel  (now > route.deadline)
```

The two write windows are disjoint (`≤` vs strict `>`), so fulfill and cancel cannot both succeed for one intent.
`fulfill` rejects `claimant == CANCELLED` so the sentinel can only be written by `cancel`.

### 3.2 Wire

Unchanged: `[destinationChainId: u64 BE (8 B)] ‖ N × [intentHash (32 B) ‖ claimant (32 B)]` on message-bridge
provers and Polymer's event, and the existing Borsh `ProveArgs` on the SVM local path. A cancelled intent is a pair
whose claimant is `CANCELLED`.

### 3.3 Source interpretation

| Proof state for `(intentHash, destination)` | `withdraw` | `refund` |
|---|---|---|
| none, or proven on another destination | revert (EVM: challenge wrong-destination proof, as today) | only when `now ≥ reward.deadline` |
| Fulfilled (real claimant) | pays claimant | only after withdrawn (as today) |
| **Cancelled** | **revert** | **allowed immediately** |

## 4. EVM destination — `contracts/Inbox.sol`

```solidity
bytes32 public constant CANCELLED = keccak256("eco.portal.intent.cancelled");

event IntentCancelled(bytes32 indexed intentHash);   // IInbox
error RouteNotExpired(uint64 deadline);              // IInbox
error ReservedClaimant();                            // IInbox

function cancel(bytes32 intentHash, Route calldata route, bytes32 rewardHash) external;
function cancelAndProve(
    bytes32 intentHash, Route calldata route, bytes32 rewardHash,
    address prover, uint64 sourceChainDomainID, bytes calldata data
) external payable;
```

`cancel` (permissionless):
1. `route.portal == address(this)` else `InvalidPortal`.
2. `keccak256(abi.encodePacked(CHAIN_ID, keccak256(abi.encode(route)), rewardHash)) == intentHash` else `InvalidHash`.
3. `block.timestamp > route.deadline` else `RouteNotExpired`.
4. `claimants[intentHash] == 0` else `IntentAlreadyFulfilled`.
5. `claimants[intentHash] = CANCELLED`; emit `IntentCancelled`.

No funds move. `cancelAndProve` mirrors `fulfillAndProve`: cancel, then `prove` for the single hash, so a
refund service needs one transaction.

`_fulfill`: add `if (claimant == CANCELLED) revert ReservedClaimant();` next to the existing `ZeroClaimant` check.

`prove`: unchanged. It emits the existing `IntentProven(intentHash, CANCELLED)` for cancelled intents.

## 5. SVM destination — `programs/portal`

**New `cancel` instruction.** `CancelArgs { intent_hash: Bytes32, route: Route, reward_hash: Bytes32 }`;
accounts `payer` (signer, mut), `fulfill_marker` (mut, PDA `["fulfill_marker", intent_hash]`), `system_program`.
1. `route.portal == crate::ID`.
2. `route.deadline < now()` (strict; `fulfill` allows `route.deadline >= now`) else `RouteNotExpired` (existing).
3. `intent_hash(CHAIN_ID, route.hash(), reward_hash) == args.intent_hash` else `InvalidIntentHash`.
4. Create the marker via `eco_svm_std::account::create_account` as
   `FulfillMarker { claimant: CANCELLED, payer, deadline: route.deadline, bump }`. If the PDA already holds a
   marker or tombstone, creation fails → `IntentAlreadyFulfilled`.
5. Emit `IntentCancelled { intent_hash }`.

**`fulfill`:** reject `claimant == CANCELLED` with new `ReservedClaimant`.

**Tombstone (`close_fulfill_marker`).** Same access rules as today (only the stored `payer`, only after
`deadline < now`). Instead of closing the account it rewrites the same PDA in place to

```rust
#[account] pub struct FulfillTombstone { pub claimant: Bytes32 }   // 8 + 32 = 40 bytes
```

resizes it to 40 bytes and transfers the freed lamports to `payer` (the Portal owns the account, so it debits it
directly). Emits the existing `FulfillMarkerClosed` with the refunded lamports. Consequences:
- The PDA still exists → both `fulfill` and `cancel` keep failing on it.
- `prove` accepts either discriminator (`FulfillMarker` or `FulfillTombstone`) and reads `claimant`, so closing no
  longer makes an intent unprovable.
- A tombstone cannot be closed again (wrong discriminator).
- Rent: marker (128+81)×6960 ≈ 1,454,640 lamports; tombstone (128+40)×6960 ≈ 1,169,280; closing refunds
  ≈ 285,360 lamports (~20%).

**Errors** are appended to `PortalError` (Anchor codes are positional): `ReservedClaimant`, `IntentCancelled`.

## 6. EVM source

### 6.1 `IProver`

```solidity
enum Outcome { None, Fulfilled, Cancelled }   // None = not proven
struct ProofData { address claimant; uint64 destination; Outcome outcome; }   // still one storage slot
event IntentCancellationProven(bytes32 indexed intentHash, uint64 destination);
```

Existence of a proof is `outcome != None` everywhere (no longer `claimant != address(0)`).
A Cancelled proof is `{ claimant: address(0), destination, outcome: Cancelled }`.

### 6.2 Provers

- **`BaseProver._processIntentProofs`** (Hyper, LayerZero, Meta, CCIP): before the `isValidAddress` skip, if
  `claimantBytes == CANCELLED` record a Cancelled proof and emit `IntentCancellationProven`. Real claimants record
  `outcome: Fulfilled`. The already-proven skip checks `outcome != None` (first recorded wins, D7).
- **`BaseProver.challengeIntentProof`:** challenge when `outcome != None && destination != expected`.
- **`PolymerProver.validate` / `processIntent`:** the same sentinel mapping before its `>> 160` skip; existence via
  `outcome`.
- **`LocalProver.provenIntents`:** if `claimants[h] == CANCELLED` return `{0, CHAIN_ID, Cancelled}` (checked first);
  real claimants return `outcome: Fulfilled`.
- **`AggregatorProver.provenIntents`:** decode the three-word tuple; return the first member (priority order) with
  `outcome != None`. Its raw-returndata hardening (length checks, rejecting fabricated tuples) extends to the third
  word; an out-of-range enum value is treated as a malformed member and skipped.

### 6.3 `IntentSource`

```
_validateRefund:
  proof = (prover has code) ? provenIntents(h) : empty
  if proof.outcome == Cancelled && proof.destination == destination: return          // fast path
  if proof.outcome == None || proof.destination != destination:
      require(block.timestamp >= reward.deadline)                                     // fallback, unchanged
      return
  require(status != Initial && status != Funded)                                      // Fulfilled, unchanged
withdraw:
  challenge branch keys on (proof.outcome != None && proof.destination != destination)
  _validateWithdraw additionally requires proof.outcome == Fulfilled
```

## 7. SVM source — `programs/portal`

- `eco-svm-std` gains `pub const CANCELLED: Bytes32` (golden-pinned to the EVM keccak bytes). `Proof`,
  hyper-prover, local-prover and flash-fulfiller are unchanged in code; they are rebuilt only because they embed
  Portal PDAs (§8).
- **`withdraw` / `validate_proof`:** reject a proof whose `claimant == CANCELLED` with `IntentCancelled`.
  This is the critical guard: SVM `withdraw` does not require the claimant to sign, so without it anyone could
  pay a cancelled intent's reward to the `CANCELLED` address.
- **`refund` / `validate_intent_status`:**
  1. withdrawn marker exists → allowed (unchanged);
  2. proof for this destination with `claimant == CANCELLED` → allowed (fast path);
  3. proof for this destination with any other claimant → `IntentFulfilledAndNotWithdrawn` (unchanged);
  4. otherwise → require `reward.deadline <= now` (unchanged).
- **Rent:** on the fast path `refund` CPIs the prover's `close_proof` (same shape as `withdraw`: new accounts
  `proof` (now mut), `proof_closer`, `prover`, plus a trailing remaining-accounts tail after the token chunks), so
  the hyper-prover's `pda_payer` rent is returned.

## 8. Rollout

- **EVM:** deploy a new Portal and redeploy every prover (each pins `PORTAL` as an immutable); new source and
  destination provers whitelist each other on every chain. The old Portal keeps settling in-flight intents
  unchanged.
- **SVM:** one atomic release — portal, local-prover, hyper-prover, flash-fulfiller — under new program IDs, per
  the repo's release rule; new EVM↔SVM Hyperlane whitelists ship with it.
- **Legacy activation gate (Notion requirement) is structural:** the fast path exists only for intents whose
  `route.portal` is the new Portal and whose `reward.prover` is a new-generation prover. Old intents never get
  `cancel`, so the closed-SVM-marker and non-upgradeability concerns do not apply to them.
- **Generation isolation:** provers accept `prove` only from their own `PORTAL`, and source provers accept
  messages only from whitelisted senders, so a new-generation sentinel never reaches an old source prover.
- **Versioning:** minor release on both repos (D8).

## 9. Safety invariants (each has a P0 test)

1. At most one of {fulfill, cancel} succeeds per intent on the destination, on both VMs, including after SVM
   marker closure.
2. A Cancelled proof never pays a claimant (`withdraw` reverts on both VMs).
3. A Fulfilled proof never enables refund before withdraw (unchanged).
4. Without a proof, refund still requires `reward.deadline` (unchanged).
5. Only the destination Portal can write `CANCELLED` (`fulfill` rejects it as a claimant).
6. An unaware EVM reader of a Cancelled proof sees "unproven" (claimant 0).
7. `CANCELLED` bytes are identical on both VMs.

## 10. Testing

| Area | EVM (Foundry: `test/core`, `test/source`, `test/prover`) | SVM (`integration-tests/tests`, unit goldens) |
|---|---|---|
| Time boundaries | cancel reverts at `now == route.deadline`, succeeds at `+1`; fulfill at `deadline` still works | same |
| Mutual exclusion | cancel after fulfill reverts; fulfill after cancel reverts; fulfill with `CANCELLED` reverts | same, plus cancel over a tombstone reverts; prove from a tombstone works; tombstone cannot be re-closed |
| Fast refund | proven Cancelled → refund before `reward.deadline` via Hyper, LayerZero, Meta, CCIP, Polymer, Local, Aggregator | Hyper and Local; `close_proof` returns rent to `pda_payer` |
| Withdraw guard | withdraw on Cancelled reverts for every prover | withdraw with claimant account `== CANCELLED` reverts |
| Fallback | no proof → refund only after `reward.deadline`; Fulfilled blocks refund | same |
| Conflicts | first recorded wins per prover; Aggregator priority; wrong-destination challenge deletes a Cancelled proof | disagreeing redelivery reverts |
| Fail-safe | a two-word `(address,uint64)` decoder of a Cancelled `ProofData` sees claimant 0 | n/a |
| Cross-VM | golden: `CANCELLED` matches the SVM constant | golden: matches EVM keccak |
| Tombstone rent | n/a | lamports refunded == marker rent − tombstone rent |

## 11. Follow-ups and known gaps (out of scope)

- **solver-v2:** interpret destination `IntentProven(hash, CANCELLED)` and source `IntentCancellationProven`; keep all
  `ExpirationValidation` / PAR-221 guards.
- **Refund service:** drive `cancelAndProve` (EVM) / `cancel` + `prove` in one transaction (SVM) after
  `route.deadline`; record which refund path was used.
- **routes-ts / indexers:** new ABI entries, events, and the sentinel.
- **Existing gap:** SVM hyper-prover `handle` ignores the Hyperlane `origin` domain, whereas EVM cross-checks the
  header chain id. Cancellation does not widen it; track separately.
