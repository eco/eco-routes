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
| D9 | **Accepted risk:** the new EVM `IntentSource` reads proofs with the typed three-word call; an intent whose `reward.prover` is a pre-change (two-word) prover can neither withdraw nor refund | Decided 2026-09-24. Creators must name new-generation provers. Rejected: a length-tolerant low-level read (costs Portal bytecode, which is 926 B under EIP-170). |
| D10 | EIP-170: if `Portal`/`PortalTron` exceed 24,576 B, stop and decide the cut with measured sizes | Decided 2026-09-24. Tripped at Task 2 (`cancelAndProve`): Portal 24,727 B at runs=1,000,000. **Resolution (user, 2026-09-24): `foundry.toml` `optimizer_runs` 1,000,000 → 10,000** → 22,067 B (2,509 B margin). Measured: runs 100,000 = 24,727 B; 1,000 = 21,038 B; 200 = 19,902 B. |

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
// IIntentSource: error CancelledIntent(bytes32 intentHash) — withdraw on a Cancelled proof. Not `IntentCancelled`:
// Solidity forbids an error sharing the IInbox event's name in Portal.

function cancel(bytes32 intentHash, Route memory route, bytes32 rewardHash) external;
function cancelAndProve(
    bytes32 intentHash, Route memory route, bytes32 rewardHash,
    address prover, uint64 sourceChainDomainID, bytes memory data
) external payable;
```

`cancel` (permissionless), as built:
1-2. Shared internal `_validateRoute(intentHash, route, rewardHash)` helper, factored out of `fulfill` so `cancel`
     reuses it verbatim: `route.portal == address(this)` else `InvalidPortal`; `keccak256(abi.encodePacked(CHAIN_ID,
     keccak256(abi.encode(route)), rewardHash)) == intentHash` else `InvalidHash`.
3. `block.timestamp > route.deadline` else `RouteNotExpired`.
4. `claimants[intentHash] == 0` else `IntentAlreadyFulfilled`.
5. `claimants[intentHash] = CANCELLED`; emit `IntentCancelled`.

No funds move. `cancelAndProve` mirrors `fulfillAndProve`: cancel, then `prove` for the single hash, so a
refund service needs one transaction. `cancel`/`cancelAndProve` take `Route memory` rather than `calldata`
(matching `fulfill`'s existing signature) — the external selector is unaffected.

`_fulfill`: add `if (claimant == CANCELLED) revert ReservedClaimant();` next to the existing `ZeroClaimant` check.

`prove`: unchanged. It emits the existing `IntentProven(intentHash, CANCELLED)` for cancelled intents.

On the source, `IntentSource.withdraw` reverts `CancelledIntent(intentHash)` (the `IIntentSource` error above,
not `IInbox.IntentCancelled`) for a Cancelled proof — see §6.3 for the exact order. `batchWithdraw` calls
`withdraw` in a plain loop with no try/catch, so one Cancelled entry reverts the whole batch atomically; a caller
cannot skip past it to still collect the batch's other entries in the same call.

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

**IDL:** neither `FulfillMarker` nor `FulfillTombstone` appears in the portal IDL — the IDL only lists account
types used as typed `Account<...>` fields, and `fulfill`/`cancel`/`prove`/`close_fulfill_marker` all take the
marker PDA as an unchecked account instead. Both are Anchor accounts at `FulfillMarker::pda(intent_hash)`
(seeds `[b"fulfill_marker", intent_hash]`), Borsh-encoded after an 8-byte discriminator, distinguished by that
discriminator. Full byte layouts (offsets, discriminators, `fulfill_marker_layout_deterministic` /
`fulfill_tombstone_layout_deterministic` golden pins) are documented in `eco-routes-svm`'s
`docs/proven-cancellation.md`, not duplicated here.

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

- **`BaseProver._recordProof`** (shared by `_processIntentProofs` for Hyper/LayerZero/Meta/CCIP and called
  directly by `PolymerProver.validate`): before the `isValidAddress` skip, if `claimantBytes == CANCELLED` record
  a Cancelled proof (`claimant: address(0)`) and emit `IntentCancellationProven`; real claimants record
  `outcome: Fulfilled` and skip a zero/invalid-address claimant as before. The already-proven skip checks
  `outcome != None` (first recorded wins, D7).
- **`BaseProver.challengeIntentProof`:** challenge when `outcome != None && destination != expected`.
- **`PolymerProver.validate`:** calls the shared `_recordProof` directly rather than reimplementing the mapping —
  a zero claimant (real or malformed) is skipped by `_recordProof`'s own `claimant == address(0)` check, not by
  separate Polymer-specific logic.
- **`LocalProver.provenIntents`:** if `claimants[h] == CANCELLED` return `{0, CHAIN_ID, Cancelled}` (checked first);
  real claimants return `outcome: Fulfilled`.
- **`AggregatorProver.provenIntents`:** decode each member's raw returndata as `(bytes32 rawClaimant, uint256
  rawDestination, uint256 rawOutcome)`, requiring exactly 96 bytes; return the first member (priority order)
  matching either: `rawOutcome == Fulfilled` with a valid non-zero, non-`0x20`-fabricated claimant, or
  `rawOutcome == Cancelled` with `rawClaimant == bytes32(0)` — a Cancelled tuple carrying any claimant bits is
  treated as malformed and skipped, exactly like a bad shape. `rawDestination` must fit `uint64` and be non-zero.
  An out-of-range `rawOutcome` (anything but `Fulfilled` or `Cancelled`) matches neither branch and the member is
  skipped like a wrong length. Members must return the three-word tuple; the deploy script's member-validation
  probe rejects the pre-cancellation two-word shape.

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
  // Order matters: the wrong-destination challenge is evaluated first and returns early,
  // so a Cancelled proof recorded for a DIFFERENT destination is challenged (deleted), never
  // reverted with CancelledIntent; only a Cancelled proof matching THIS destination reaches
  // _validateWithdraw and its CancelledIntent revert.
  challenge branch keys on (proof.outcome != None && proof.destination != destination)
  _validateWithdraw additionally requires proof.outcome == Fulfilled, else CancelledIntent
    (Cancelled) or InvalidClaimant (None/claimant zero)
```

## 7. SVM source — `programs/portal`

As built (`eco-routes-svm`, user-approved rulings 2026-09-25; full client-visible detail in that repo's
`docs/proven-cancellation.md`):

- `eco-svm-std` gains `pub const CANCELLED: Bytes32` (golden-pinned to the EVM keccak bytes). `Proof`,
  hyper-prover, local-prover and flash-fulfiller are unchanged in code; they are rebuilt only because they embed
  Portal PDAs (§8).
- **`withdraw`:** fails with the new error `IntentCancelled` when the proof's claimant is `CANCELLED`.
  This is the critical guard: SVM `withdraw` does not require the claimant to sign, so without it anyone could
  pay a cancelled intent's reward to the `CANCELLED` address.
- **`refund`:** the account list and `RefundArgs` shape change (a breaking change, acceptable only because each
  release deploys under new program IDs — never upgrade a deployed portal in place). Accounts, in order: `payer`
  (signer, mut), `creator` (mut), `vault` (mut), `proof` (**now mut**), `proof_closer` (**new**,
  `proof_closer_pda(reward.prover)`), `prover` (**new**, must equal `reward.prover`), `withdrawn_marker` (mut),
  `token_program`, `token_2022_program`, `system_program`, then remaining accounts: the token chunks, followed by
  the close-proof tail. `RefundArgs` gains `close_proof_account_count: u8`, the number of trailing remaining
  accounts forwarded to the prover's `close_proof` (`0` when no proof is closed). Paths, checked in this order:
  1. Withdrawn marker exists → refunds leftovers as before.
  2. Proof for this destination with `claimant == CANCELLED` → refundable **at any time** (fast path). The proof
     is **always** closed via the prover's `close_proof` (the close-proof tail is therefore always required, and
     `reward.prover` must be an executable program or the refund fails `InvalidProver`) — there is no SVM source
     tombstone; closing the proof is how its rent comes back. `reward.deadline` decides only which token chunks
     are required, not whether the fast path is available:
     - **Before `reward.deadline`:** the token chunks must sweep **every** reward mint — each mint in
       `reward.tokens` needs a chunk sourced from the vault's ATA for that mint, or the refund fails
       `InvalidMint` and nothing moves (a griefing guard: a partial-mint refund cannot be used to leave the rest
       stranded). Extra non-reward-mint chunks remain allowed. Every reward mint's vault ATA must therefore exist
       and be transferable; a client should create any missing one idempotently in the same transaction.
     - **From `reward.deadline` on:** the refund sweeps whatever chunks it is given, like a timeout refund, so a
       reward mint that cannot be swept (closed, frozen, non-transferable/transfer-hook mint, or a missing vault
       ATA) may be omitted instead of locking the rest — a liveness escape hatch once the deadline has passed.
     - The fast path is live only while `reward.prover` can actually close its proofs, which is why production
       provers must be deployed **finalized** (no upgrade authority): a finalized, non-upgradeable prover can
       never fail to have a working `close_proof`, so this path cannot be bricked by a prover upgrade.
  3. Proof for this destination with any other claimant (fulfilled, not withdrawn) → `IntentFulfilledAndNotWithdrawn`
     (unchanged).
  4. Otherwise (no proof, or a proof for another destination) → require `reward.deadline <= now`, as before.
- **`prove`:** proves a cancelled intent exactly like a fulfilled one (claimant `CANCELLED`), reading the claimant
  from a `FulfillMarker` **or** a `FulfillTombstone`, and only from an account the Portal owns (`fulfillment_claimant`
  requires portal ownership; `InvalidFulfillMarker` otherwise).
- **Close-proof tail signer hygiene:** hyper-prover's `close_proof` takes `pda_payer` (mut), which receives the
  proof's rent; local-prover's takes `payer` (mut, **signer**) instead. Because the tail is forwarded to
  `reward.prover` as-is, a refund service must forward a signer in the tail only to provers it allowlists — a
  signer passed to an unknown `reward.prover` is a signer that program can use for anything.

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
  `ExpirationValidation` / PAR-221 guards. **Release gate:** solver-v2's SVM executors currently treat "the
  `fulfill_marker` PDA exists" as "already fulfilled" (`recoverAlreadyFulfilledWithProgram` in
  `src/modules/blockchain/svm/services/svm.executor.service.ts:439`, via `checkPdaExists`; and
  `hasFulfillMarker` in `src/modules/blockchain/svm/services/svm-standard-fulfillment.executor.ts:373`), without
  reading the claimant. Against the new SVM program this misreads a cancelled intent as fulfilled and cannot
  distinguish a live `FulfillMarker` from a `FulfillTombstone`. Both call sites must read the claimant (recognizing
  `CANCELLED` and both account discriminators) before the new program IDs carry solver-v2 traffic.
- **Refund service:** drive `cancelAndProve` (EVM) / `cancel` + `prove` in one transaction (SVM) after
  `route.deadline`; record which refund path was used. On SVM, before `reward.deadline` it must pass every reward
  mint's vault-ATA chunk (§7) or the fast-path refund fails `InvalidMint`; it must also forward a close-proof
  tail signer only to allowlisted provers, never to an untrusted `reward.prover`.
- **routes-ts / indexers:** new ABI entries, events, and the sentinel.
- **Existing gap:** SVM hyper-prover `handle` ignores the Hyperlane `origin` domain, whereas EVM cross-checks the
  header chain id. Cancellation does not widen it; track separately.
