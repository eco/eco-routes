# v3 migration-loss inventory

Deliberate narrowings vs v2 / the earlier v3 draft, recorded here as they are accepted (not bugs). Each
is a consequence of a locked v3 decision.

## No zero-capital same-chain flash
v2's `flashFulfill` could borrow the reward escrow to fund the route (withdraw-before-fulfill). Under v3
the reward scales on the solver-provided `fulfilled[]` and settlement is gated on the fulfillment
preimage, and — decisively — the PR4 reward-conservation postcondition forbids the runtime from consuming
the escrow. So same-chain solving (`fulfillAndSettle`) is capital-EFFICIENT (one tx) but the solver must
supply the route input capital. Accepted: the zero-capital flow is out of scope for this stack.

**RESTORED by PR11** (`v3/11-same-chain-flash`, `docs/v3/11-same-chain-flash.md`): v2's
withdraw-before-fulfill session returns as two standalone policies with zero core diffs —
`SameChainFlashPolicy.flashFulfill` (one-shot, session self-vouching through `provenIntents`) and
`StreamingFlashPolicy.flashSlice` (standing pools, full-pool advance through a session-scoped
`consumeStreamClaims`). The advance empties the escrow BEFORE `fulfill`, so the PR4 conservation
snapshot is ~0 and the flow coexists with (rather than fights) the escrow protection. The core paths
(`fulfillAndSettle`, `LocalPolicy.flashFulfill`) remain capital-efficient-not-capital-free as described
above.

## Destination leftover retrieval on same-chain is escrow-locked
Under the unopinionated core there is no `recipient` and no auto-sweep; unconsumed solver input stays in
the intent's Account. Cross-chain, `route.keeper` retrieves it via the destination
`Inbox.executeAsOwner`. Same-chain, that path is disabled (`SourceChainOwnerOnly`) because the account is
(or collapses with) the escrow account; retrieval then flows through the source
`IntentSource.executeAsOwner`, which is subject to the `AccountLocked` escrow/proof lock. Net: same-chain
leftover is retrievable only after the escrow is free (settled / past deadline) and only by
`reward.keeper`. Accepted (safety over a minor liveness convenience); in practice a same-chain intent's
keeper sets `route.keeper == reward.keeper`.

## fulfill signature carries the full reward
`fulfill` now takes the full `Reward` (not just `rewardHash`) so the destination can authenticate the
escrow legs for reward-conservation. This re-exposes the reward struct on the destination side; it is
public data (committed on the source) and is used only for the local snapshot, so no confidentiality or
cross-VM property is lost. The intent hash still commits `rewardHash`.

## Hash-only proof: a proven intent can be refunded after the deadline
In v2 a proven intent could never be refunded. In the v3 hash-only model the source cannot introspect the
committed claimant, so the anti-griefing guarantee (a bad-claimant fulfillment cannot permanently lock the
keeper's funds) is preserved by the deadline instead: after `reward.deadline` an unsettled intent is
always refundable. Accepted (documented in `IntentSource._validateRefund`).

## batchWithdraw removed
v2 exposed a `batchWithdraw` to settle many intents in one call. v3 does not carry it — settlement is
per-intent (and, for streaming, per-batch inside one policy). Accepted: the multi-intent convenience is out
of scope; a caller batches at the tx level instead. (The generated `contracts/README.md` still documents
`batchWithdraw`; that file is stale and regenerated in PR8.)

## Destination prove-time `IntentProven` event dropped
In v2 the destination emitted an `IntentProven` at prove time. Under the v3 hash-only model the source-side
`IntentProven(intentHash, destination, fulfillmentHash)` (emitted by the policy on the source when the fact
lands — see `BasePolicy`/`PolymerPolicy`/`ScheduledPolicy`) is the authoritative proof event; the separate
destination prove-time event was removed as redundant. Accepted (an observability change, not a
correctness one).

## `IntentPublished` not extended with `hooks` (observability gap)
PR5 added `reward.hooks` but did NOT add the hooks bytes to the `IntentPublished` event. Off-chain indexers
that want the hooks must read them from the funding calldata / the committed `rewardHash` preimage rather
than the event. Accepted as a low-priority observability gap; flagged as a follow-up (extend
`IntentPublished` with `hooks`).

## Two-owner model reversed by the unopinionated core
A `route.recipient` + a separate `rescueDestination` retrieval path existed BRIEFLY during development (the
"two-owner model", a.k.a. earlier diff-review "finding #8"). The unopinionated-core decision REMOVED both:
there is no recipient, and destination retrieval is `route.keeper` via `executeAsOwner`. Recorded here so
the reversal is explicit — any reference to `route.recipient`/`rescueDestination` is stale.

## Arc kept (not deprecated)
The CCTPMint **Arc** deposit family was KEPT (alongside CCTPMint_GatewayERC20 and USDCTransfer_Solana), not
deprecated. Decision recorded so a future cleanup does not assume it was dropped.

## optimizer_runs per branch (downstream gas expectations)
`optimizer_runs` is NOT uniform across the stack — the streaming settle/close paths genuinely need a lower
value to keep `Portal`/`PortalTron` under the 24,576-byte limit. Final per-branch values (foundry.toml +
hardhat.config.ts kept in lockstep):

| branch | optimizer_runs | Portal size |
|--------|---------------:|------------:|
| v3/03 | 1,000,000 | 24,380 |
| v3/04 | 20,000 | 22,880 |
| v3/05 | 20,000 | 23,536 |
| v3/06 | 1,000 | 23,649 |
| v3/07, v3/08 | 1,000 | 23,649 |

Downstream gas/size expectations should use the per-branch value, not a single global one.

## Deferred (tracked, not lost)
- Deposit-address migration onto standing streaming intents — deferred to a PR6b follow-up; the H2
  anti-poison guard and all deposit families stay functional in the meantime.
- Root/generated docs (`README.md`, `contracts/README.md`, `localprover_flows.md`,
  `deposit_address_userflow.md`, and the `CLAUDE.md`/`SECURITY.md` policy docs) still carry v2/pre-rename
  wording (`Vault`, `Prover`, `.creator`) and pre-v3 architecture. PR8 authors the NEW v3 docs
  (`docs/v3/*`) but does NOT rewrite these — a safe rewrite (esp. the generated `contracts/README.md` and
  the governance docs) is a doc-only follow-up larger than PR8's budget. The canonical v3 reference is
  `docs/v3/` (see [`00-overview.md`](./00-overview.md)).
- TVM broadcast tooling for `runTron()` (see [`08-deploy-and-release.md`](./08-deploy-and-release.md)).

## Accepted residual risk: anti-lock refund vs. cross-chain in-flight window
`IntentSource._validateRefund` makes the reward **always refundable after `reward.deadline`**, regardless of
proof state (a terminal/proven intent still allows a dust-recovery refund). This is a deliberate trade: the
hash-only fact model gives the source no way to introspect a fulfillment's claimant before settlement, so a
bad-claimant fulfillment could otherwise permanently lock the keeper's funds — the deadline is the one
definitive settlement window instead.

The trade's edge case: a solver who fulfills a **cross-chain** intent shortly before `reward.deadline`, whose
proof has not yet been bridged and settled back to the source chain by the time the deadline passes, can be
refunded out by the keeper — the solver delivered but is not paid. (Same-chain and already-settled intents are
unaffected; streaming intents are additionally protected pre-deadline by `StreamingPolicy.provenIntents`
correctly reporting an unsettled batch as a valid proof, which blocks the generic `refund()` path the same way
`closeStream`'s explicit gate does.) Mitigation is operational, not code: **`reward.deadline` should be set
with enough margin over the slowest bridge's expected settlement time** for the intent's route. This narrow
window is unchanged in spirit from the pre-v3 design and was reviewed and accepted, not newly introduced by
this train.
