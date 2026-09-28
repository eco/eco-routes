# Proven Cancellation — Design

- **Status:** implemented on branch `cfebres/eco-2403-proven-cancellation` (eco-routes + eco-routes-svm); not yet released
- **Date:** 2026-09-24; revised 2026-09-28 (20-byte sentinel, `ProofData.outcome` removed, SVM marker permanent)
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
- **Accepted risk: cancellation proofs relayed before destination finality.** A cancellation proof relayed before
  the destination block that recorded `cancel` is final (e.g. MetaProver's `FinalityState.INSTANT`, default
  Hyperlane ISMs, LayerZero DVN confirmations, Polymer pre-confirmations), followed by a destination reorg spanning
  `route.deadline` that re-includes a pending `fulfill`, refunds the creator and leaves the solver unpaid: the
  source records the Cancelled proof first, and first recorded wins (D7), so the solver's later Fulfilled proof is
  ignored. This is accepted. Operational rule: a refund service must call `cancel`, wait for the destination block
  to be final, and only then call `prove`; it must not use `cancelAndProve` for this.
- No activation for in-flight / legacy intents: the fast path exists only on the new deployment (§8).
- No user self-attestation of any outcome. Only the destination Portal's recorded state, carried by a whitelisted
  prover, can prove a cancellation.
- Off-chain consumers (solver-v2, refund service, routes-ts, indexers) are follow-ups (§10).

## 2. Decisions

| # | Decision | Notes |
|---|---|---|
| D1 | Carry "cancelled" as a **sentinel claimant** in the existing `(intentHash, claimant)` payload | Wire format unchanged on every prover and both VMs. Rejected: per-pair outcome byte (breaks every decoder), versioned header (no version byte exists). |
| D2 | `CANCELLED = address(uint160(uint256(keccak256("eco.portal.intent.cancelled"))))` = `0xe685056aEc77686A83E2a6bDf37c6f71dD2fdB5f`; as bytes32 `0x000000000000000000000000e685056aec77686a83e2a6bdf37c6f71dd2fdb5f`, identical on both VMs | Revised 2026-09-28 (was the full 32-byte hash). Deliberately a valid EVM address, so it fits `ProofData.claimant` and every prover records it with no cancellation-specific code (D4). Hash-derived → no EVM or Solana key controls it; both `withdraw`s reject it explicitly anyway. Cost: an old-generation EVM source would treat it as a payable claimant (§8 rule 2). |
| D3 | Destination stores the sentinel in its **existing fulfillment record** (`claimants[h]` on EVM, the `FulfillMarker` PDA on SVM) | `fulfill`'s "already fulfilled" check and `prove`'s payload build then cover cancellation with no new branches. |
| D4 | **EVM source:** `ProofData` stays `{ address claimant; uint64 destination }` (unchanged from `main`); a proven cancellation is `{ claimant: CANCELLED, destination }` | Revised 2026-09-28. Superseded: a trailing `Outcome outcome` field with `claimant = address(0)` for a cancellation. Dropping it reverts the prover, `IntentSource`, `AggregatorProver` and `LocalProver` changes it forced, and removes D9. Trade-off: a reader unaware of cancellation now sees a payable claimant instead of "unproven", which makes generation isolation a hard release gate (§8). |
| D5 | **SVM source:** `Proof` layout **unchanged**; a proven cancellation is `Proof { destination, claimant: CANCELLED }` | SVM provers store claimants verbatim → zero prover changes. Old-portal/new-prover mixing is already unrecoverable on SVM (PDA-pinned `close_proof`), so an outcome field buys nothing. |
| D6 | SVM fulfill marker is **permanent**: `close_fulfill_marker` (#81) is removed, and `cancel` writes an ordinary `FulfillMarker { claimant: CANCELLED }` | Revised 2026-09-28 (was: close leaves a `FulfillTombstone`). A closed marker is indistinguishable from "never fulfilled", so `cancel` could succeed on a fulfilled intent and send the source a conflicting proof. Reclaiming marker rent after settlement is future work. |
| D7 | Conflicting outcomes: **first recorded wins**, per prover; `AggregatorProver` resolves by member priority | Deliberate deviation from the Notion spec's "explicit conflict policy" wording, decided 2026-09-24. Conflicts require a compromised prover/bridge (the destination makes the outcomes mutually exclusive). |
| D8 | Release as a **minor** version (`feat:` commits, no `BREAKING CHANGE`) | Decided 2026-09-24. Justified by D4: `ProofData` is unchanged and the new `IInbox` surface is additive. |
| D9 | ~~Accepted risk: pre-change (two-word) provers freeze intents~~ **Obsolete (2026-09-28).** | `ProofData` is two words again (D4), so any prover returning `main`'s shape works as a source prover on the new `IntentSource`. |
| D10 | EIP-170: if `Portal`/`PortalTron` exceed 24,576 B, stop and decide the cut with measured sizes | Decided 2026-09-24. Tripped at Task 2 (`cancelAndProve`): Portal 24,727 B at runs=1,000,000. **Resolution (user, 2026-09-24): `foundry.toml` `optimizer_runs` 1,000,000 → 10,000** → 22,067 B (2,509 B margin). Measured: runs 100,000 = 24,727 B; 1,000 = 21,038 B; 200 = 19,902 B. Re-measure after the D4 revision; returning to runs 1,000,000 is a separate decision. |

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
// types/Intent.sol: address constant CANCELLED_CLAIMANT = address(uint160(uint256(keccak256("eco.portal.intent.cancelled"))));
function CANCELLED() external pure returns (bytes32);   // bytes32(uint256(uint160(CANCELLED_CLAIMANT))), the value stored in claimants[h]

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
4. `claimants[intentHash] != CANCELLED` else `IntentAlreadyCancelled`; `claimants[intentHash] == 0` else
   `IntentAlreadyFulfilled`.
5. `claimants[intentHash] = CANCELLED`; emit `IntentCancelled`.

No funds move. `cancelAndProve` mirrors `fulfillAndProve`: cancel, then `prove` for the single hash, so a
refund service needs one transaction. It is idempotent after a prior `cancel`: when `claimants[intentHash]`
already holds `CANCELLED` it skips the cancel and only proves, so a third party's front-run `cancel` cannot make
it revert. `cancel`/`cancelAndProve` take `Route memory` rather than `calldata`
(matching `fulfill`'s existing signature) — the external selector is unaffected.

`_fulfill`: add `if (claimant == CANCELLED) revert ReservedClaimant();` next to the existing `ZeroClaimant` check.

`prove`: unchanged. It emits the existing `IntentProven(intentHash, CANCELLED)` for cancelled intents.

On the source, `IntentSource.withdraw` reverts `CancelledIntent(intentHash)` (the `IIntentSource` error above,
not `IInbox.IntentCancelled`) for a Cancelled proof — see §6.3 for the exact order. `batchWithdraw` calls
`withdraw` in a plain loop with no try/catch, so one Cancelled entry reverts the whole batch atomically; a caller
cannot skip past it to still collect the batch's other entries in the same call.

## 5. SVM destination — `programs/portal`

**New `cancel` instruction.** `CancelArgs { intent_hash, route, reward_hash, account_flags: Vec<u8> }`; `route` is
in `fulfill`'s compact form, with call accounts passed read-only and unsigned as remaining accounts and their
committed signer/writable bits in `account_flags`. Accounts `payer` (signer, mut), `fulfill_marker` (mut, PDA
`["fulfill_marker", intent_hash]`), `system_program`.
1. `route.portal == crate::ID`.
2. `route.deadline < now()` (strict; `fulfill` allows `route.deadline >= now`) else `RouteNotExpired`.
3. Rebuild the canonical route; `intent_hash(CHAIN_ID, route.hash(), reward_hash) == args.intent_hash` else
   `InvalidIntentHash`.
4. Create `FulfillMarker { claimant: CANCELLED, bump }` at the PDA. If it already exists, creation fails →
   `IntentAlreadyFulfilled`.
5. Emit `IntentCancelled { intent_hash }`.

**`fulfill`:** reject `claimant == CANCELLED` with new `ReservedClaimant`.

**Permanent marker (D6).** `FulfillMarker` is `{ claimant: Bytes32, bump: u8 }` (8 + 33 = 41 bytes, rent
(128 + 41) × 6960 = 1,176,240 lamports), written once by `fulfill` or `cancel` and never closed. `close_fulfill_marker`
and `FulfillMarkerClosed` are removed; `InvalidFulfillMarkerPayer` keeps its slot so later error codes do not
shift. `prove` reads the claimant from the marker, only from a portal-owned account.

**Errors** are appended to `PortalError` (Anchor codes are positional): `ReservedClaimant`, `IntentCancelled`.

**IDL:** `FulfillMarker` does not appear in the portal IDL (every instruction takes the PDA as an unchecked
account). Its byte layout and golden pin are documented in `eco-routes-svm`'s `docs/proven-cancellation.md`.

## 6. EVM source

### 6.1 `IProver`

Unchanged from `main`: `struct ProofData { address claimant; uint64 destination; }`, and a proof exists when
`claimant != address(0)`. A proven cancellation is `{ claimant: CANCELLED_CLAIMANT, destination }` and is announced
by the ordinary `IntentProven(intentHash, CANCELLED_CLAIMANT, destination)`; there is no separate cancellation event.

### 6.2 Provers

All provers are unchanged from `main`. `BaseProver._processIntentProofs`, `PolymerProver.validate` /
`validateSolana` and the rest skip only zero and non-160-bit claimants, which the sentinel is not, so it is
recorded like any claimant; first recorded wins (D7) and `challengeIntentProof` treats it like any proof.
- **`LocalProver.provenIntents`:** `claimants[h] == CANCELLED` returns `{ CANCELLED_CLAIMANT, CHAIN_ID }` like any
  recorded claimant.
- **`AggregatorProver.provenIntents`:** returns the first member (priority order) whose proof has a non-zero
  claimant, so a cancellation resolves exactly like a fulfillment.

### 6.3 `IntentSource`

```
_validateRefund:
  proof = (prover has code) ? provenIntents(h) : empty
  if proof.destination == destination:
      if proof.claimant == CANCELLED_CLAIMANT: return                                 // fast path
      if proof.claimant != 0: require(status != Initial && status != Funded)          // Fulfilled, unchanged
                              return
  require(block.timestamp >= reward.deadline)                                         // fallback, unchanged
withdraw:
  // The wrong-destination challenge runs first and returns early, so a cancellation proven for a
  // DIFFERENT destination is challenged (deleted), never reverted with CancelledIntent.
  challenge branch unchanged: (proof.claimant != 0 && proof.destination != destination)
  _validateWithdraw: claimant == CANCELLED_CLAIMANT → CancelledIntent; claimant == 0 → InvalidClaimant
```

The `CancelledIntent` check is the load-bearing guard: `withdraw` is permissionless and would otherwise send the
reward to the sentinel address, where it is burned.

## 7. SVM source — `programs/portal`

As built (`eco-routes-svm`, user-approved rulings 2026-09-25; full client-visible detail in that repo's
`docs/proven-cancellation.md`):

- `eco-svm-std` gains `pub const CANCELLED: Bytes32` = 12 zero bytes ‖ `keccak256("eco.portal.intent.cancelled")[12..]` (golden-pinned to the EVM `IInbox.CANCELLED()` bytes). `Proof`,
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
  from the `FulfillMarker`, and only from an account the Portal owns (`fulfillment_claimant`
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
  messages only from whitelisted senders, so a new-generation sentinel reaches an old source prover only through a
  misconfigured whitelist or a reused SALT (rule 2).
- **Versioning:** minor release on both repos (D8).
- **Fund-safety rules for this rollout (not optional, both must hold together):**
  1. **New root SALT for this (and every) release with a new Portal.** CREATE3 ignores bytecode: each prover's address depends only on `(deployer, SALT)`, while the Portal is CREATE2 and moves with its bytecode (which every release changes, since the release flow rewrites `version()`). So ANY release run with an unchanged root `SALT` — not just this one's optimizer change (D10) — lands every prover on the previous release's address, where `deployWithCreate3` finds the old prover (bound to the OLD Portal) and skips deploying. No intent on the new Portal could then be proven, withdrawn or refunded. `Deploy.s.sol` now fails closed on this: when a prover address is already occupied it requires `PORTAL()` to equal this run's Portal and `provenIntents` to return the expected shape (`_requireReusableProver`), and reverts before broadcast naming the prover otherwise; a same-release re-run still passes. The fix is a NEW root `SALT` (documented in `RELEASE.md` and `scripts/README.md`). Downstream, `eco-routes-deployer`'s CREATE3 salts must be re-mined, `scripts/sync-artifacts.ts` and its committed artifacts updated to `runs: 10,000` (the deployer's byte-for-byte self-check against the old artifacts will fail by design — that failure is expected, not a regression), and `LocalProver`'s CREATE2 address changes too (it is bytecode-derived, not salt-derived). The `build:` optimizer-config commit does not itself ship a feature, so it will not appear in the Conventional-Commits changelog (D8) — add it to the release notes by hand.
  2. **Generation isolation is a fund-safety rule, not an assumption (burn risk).** An old-generation source prover (EVM or SVM) has no concept of `CANCELLED`: the 20-byte sentinel is a valid EVM address (D2), so an old EVM source prover records it as an ordinary claimant, and the old SVM portal stores claimants verbatim. Both old `withdraw`s are permissionless and would pay the reward to the sentinel address, burning it. This can only happen if a new-generation destination prover can message an old-generation source prover: a reused root SALT (rule 1; the reuse guard does not catch a stale SALT on a chain with no provers yet) or a cross-generation whitelist. Whitelists must be wired generation-to-generation, never across, and every release must use a new root SALT. Accepted as a release gate (docs only, decided 2026-09-28), recorded in `RELEASE.md`.

## 9. Safety invariants (each has a P0 test)

1. At most one of {fulfill, cancel} succeeds per intent on the destination, on both VMs (the SVM marker is never
   closed).
2. A Cancelled proof never pays a claimant (`withdraw` reverts on both VMs).
3. A Fulfilled proof never enables refund before withdraw (unchanged).
4. Without a proof, refund still requires `reward.deadline` (unchanged).
5. Only the destination Portal can write `CANCELLED` (`fulfill` rejects it as a claimant).
6. `CANCELLED` is a valid EVM address that no key controls, and every new-generation source rejects it in `withdraw`
   (old generations must never receive it, §8 rule 2).
7. `CANCELLED` bytes are identical on both VMs.

## 10. Testing

| Area | EVM (Foundry: `test/core`, `test/source`, `test/prover`) | SVM (`integration-tests/tests`, unit goldens) |
|---|---|---|
| Time boundaries | cancel reverts at `now == route.deadline`, succeeds at `+1`; fulfill at `deadline` still works | same |
| Mutual exclusion | cancel after fulfill reverts; fulfill after cancel reverts; fulfill with `CANCELLED` reverts | same (the marker is permanent) |
| Fast refund | proven Cancelled → refund before `reward.deadline` via Hyper, LayerZero, Meta, CCIP, Polymer, Local, Aggregator | Hyper and Local; `close_proof` returns rent to `pda_payer` |
| Withdraw guard | withdraw on Cancelled reverts for every prover | withdraw with claimant account `== CANCELLED` reverts |
| Fallback | no proof → refund only after `reward.deadline`; Fulfilled blocks refund | same |
| Conflicts | first recorded wins per prover; Aggregator priority; wrong-destination challenge deletes a Cancelled proof | disagreeing redelivery reverts |
| Shape | a prover returning `main`'s two-word `ProofData` works as a source prover; `provenIntents(h).claimant == CANCELLED` after a cancellation, with `IntentProven` | n/a |
| Cross-VM | `IInbox.CANCELLED()` == `0x000…e685056aec77686a83e2a6bdf37c6f71dd2fdb5f` and == low 20 bytes of the hash | golden: the same 32 bytes; upper 12 bytes zero |

## 11. Follow-ups and known gaps (out of scope)

- **solver-v2:** interpret destination and source `IntentProven(hash, CANCELLED)` as a cancellation (never withdraw it); keep all
  `ExpirationValidation` / PAR-221 guards. **Release gate:** solver-v2's SVM executors currently treat "the
  `fulfill_marker` PDA exists" as "already fulfilled" (`recoverAlreadyFulfilledWithProgram` in
  `src/modules/blockchain/svm/services/svm.executor.service.ts:439`, via `checkPdaExists`; and
  `hasFulfillMarker` in `src/modules/blockchain/svm/services/svm-standard-fulfillment.executor.ts:373`), without
  reading the claimant. Against the new SVM program this misreads a cancelled intent as fulfilled. Both call sites must read the marker's
  claimant (recognizing `CANCELLED`) before the new program IDs carry solver-v2 traffic.
- **solver-v2 EVM claimant readers have the same gap.** `EvmExecutorService.readOnChainClaimant` (`src/modules/blockchain/evm/services/evm.executor.service.ts:3001`) treats any non-zero `claimants[intentHash]` as fulfilled, with no awareness of the `CANCELLED` sentinel (D4). It is used by `readClaimantState` (`:2222`), the execution-retry guard (`:3042`), and `assertNotAlreadyFulfilledOnDroppedAttestation` (`:3074`, the dropped-Gateway-attestation refund guard). Against the new Portal, all three misread a cancelled intent as fulfilled: `readClaimantState` reports `'fulfilled'`, the retry guard treats the intent as settled and stops retrying, and the dropped-attestation guard withholds the refund it exists to allow. **Release gate:** all three must recognize `CANCELLED` before solver-v2 serves traffic against the new Portal. `EvmReaderService.classifyProvenClaimant`'s withdrawal preflight (`evm.reader.service.ts:1236`) must also classify a `CANCELLED` claimant as cancelled, not as a withdrawable proof: under D4 as revised the source proof carries the sentinel, not claimant 0.
- **EVM: a second `cancel` reverts `IntentAlreadyCancelled`, distinct from `IntentAlreadyFulfilled`, and `cancelAndProve` on an already-cancelled intent skips the cancel and proves.** A front-run or retried `cancel` therefore never looks like a fulfillment on EVM. SVM still reports an already-cancelled intent with the same error as a fulfilled one (the marker creation fails, §3.1), so an SVM refund service must read the marker account to distinguish "already cancelled → skip straight to `prove`" from "already fulfilled → do not refund".
- **Refund service:** drive `cancelAndProve` (EVM) / `cancel` + `prove` in one transaction (SVM) after
  `route.deadline`; record which refund path was used. On SVM, before `reward.deadline` it must pass every reward
  mint's vault-ATA chunk (§7) or the fast-path refund fails `InvalidMint`; it must also forward a close-proof
  tail signer only to allowlisted provers, never to an untrusted `reward.prover`.
- **routes-ts / indexers:** new ABI entries, events, and the sentinel.
- **Existing gap:** SVM hyper-prover `handle` ignores the Hyperlane `origin` domain, whereas EVM cross-checks the
  header chain id. Cancellation does not widen it; track separately.
