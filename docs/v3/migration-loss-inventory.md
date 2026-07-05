# v3 migration-loss inventory

Deliberate narrowings vs v2 / the earlier v3 draft, recorded here as they are accepted (not bugs). Each
is a consequence of a locked v3 decision.

## No zero-capital same-chain flash
v2's `flashFulfill` could borrow the reward escrow to fund the route (withdraw-before-fulfill). Under v3
the reward scales on the solver-provided `fulfilled[]` and settlement is gated on the fulfillment
preimage, and — decisively — the PR4 reward-conservation postcondition forbids the runtime from consuming
the escrow. So same-chain solving (`fulfillAndSettle`) is capital-EFFICIENT (one tx) but the solver must
supply the route input capital. Accepted: the zero-capital flow is out of scope for this stack.

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

## Deferred (tracked, not lost)
- Deposit-address migration onto standing streaming intents — deferred to a PR6b follow-up; the H2
  anti-poison guard and all deposit families stay functional in the meantime.
- Generated `contracts/README.md` and the root docs still carry v2/pre-rename wording — regenerated in the
  deploy/docs stage (PR8).
