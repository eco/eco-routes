# PR6 — lean streaming policy + Portal settle/close + H2 anti-poison

> Adds a content-addressed `StreamingPolicy` for standing (re-fulfillable) intents, the source-side
> `settleStream`/`closeStream` entry points, `Account.withdrawStream`, and the H2 anti-poison guard in the
> core Inbox. Re-authored onto PR5 (rename-clean; the streaming policy calls into the Account, not a Vault).

## 1. StreamingPolicy (content-addressed, NOT FIFO)

A standing intent (reusable deposit address) is fulfilled MANY times. The policy is content-addressed, not
a FIFO queue:

- **Destination**: each `recordFulfillment` appends the slice's `fulfillmentHash` to `_destHashes[ih]`
  (never reverts → the intent is re-fulfillable) and emits the preimage.
- **prove**: hashes the accumulated dest slice list into ONE `batchHash`
  (`keccak(intentHash, batchNonce, sliceHashes[])`, monotonic `batchNonce` prevents collision) and
  DELETES `_destHashes[ih]`.
- **Source**: records each `batchHash` with PERMANENT dedup (`batchSeen` — fixes the M1 re-record wedge).
- **settle**: the caller supplies the batch's slice preimages; the policy verifies them against the stored
  `batchHash`, removes consumed slices by swap-pop (no FIFO → fixes H1 stranding), and returns the per-leg
  payout table.
- **close**: `closeStream` is gated on `!hasUnsettledFulfillment` (fixes the C2 rug — a keeper can't
  reclaim escrow owed to a solver whose batch is proven-but-unsettled).

## 2. Source entry points

- `IntentSource.settleStream(source, destination, routeHash, reward, batchData)` — source-chain-gated.
  The `StreamingPolicy.consumeStreamClaims` verifies + consumes the batches and returns the payout table
  as opaque `bytes`; `Account.withdrawStream` decodes it and pays each slice's leg IN FULL or reverts
  (`StreamSlicePayoutExceedsBalance`) — so an under-funded batch is never partially consumed and its
  shortfall is recoverable after a top-up (L1). The residual is NOT swept (it funds later slices). The
  intent stays `Funded` (re-fulfillable). Emits `StreamSettled`.
- `IntentSource.closeStream(source, destination, routeHash, reward)` — keeper-only (`reward.keeper`),
  source-chain-gated, C2-gated on `!hasUnsettledFulfillment` (`PendingProofBlocksClose`). Marks the stream
  closed on the policy, sets the intent `Refunded`, and returns the remaining escrow to the keeper. Emits
  `StreamClosed`. (The refund hook is intentionally not run here — this is the streaming reclaim path.)

The Portal handles the nested `StreamBatch[]` / payout-table types ONLY as opaque `bytes` at its boundary
— the decode lives in `StreamingPolicy` + `Account` — keeping the tight Portal small.

## 3. H2 anti-poison (core Inbox)

`Inbox._fulfill` reverts `NothingToFulfill` when `route.minTokens.length == 0 && reward.tokens.length == 0`.
Such an intent asks a solver to provide nothing for no pay, so there is no honest fulfill — and recording
one would permanently occupy the prover's fulfillment store, bricking a REUSABLE deposit address for every
later deposit. The only legitimate way to run such an Account's committed `runtime(payload)` is the
owner-gated `executeAsOwner`.

## 4. Size budget

Portal / PortalTron = 23,649 B (headroom 927) at `optimizer_runs = 1,000`. The streaming settle/close
entry points (their two extra `getIntentHash` inlines each ABI-encode the nested `Reward`) push the Portal
to 25,058 B at 20,000 runs, so the optimizer valve is lowered (foundry.toml + hardhat.config.ts in
lockstep). Bytecode SIZE plateaus at the ceiling for high runs; below the plateau, lower runs trade a
little runtime gas for real bytecode headroom. Externalizing the struct-heavy decode to the policy/Account
(opaque `bytes` at the Portal boundary) already recovered ~1 KB; the valve closes the rest.

## 5. Accepted residual: relay-mistag wipe via `challengeIntentProof`

`challengeIntentProof` is permissionless and deletes all of an intent's `_srcBatches` when the recorded
`srcDestination` doesn't match the intent's real `destination`. `recordBatch` takes `intentHash` and
`destination` as independent arguments, so a **whitelisted** relay that records a genuine batch under the
wrong `destination` lets anyone permissionlessly wipe that intent's accumulated, proven-but-unsettled
batches — the solver only recovers by re-proving. This requires an already-trusted relay to misbehave or
have a bug (the same trust bar the relay whitelist already assumes for censorship-resistance), not an
unprivileged attacker, and it's the wrong-destination scrub working as designed for the honest case — but
it's a sharp correctness dependency on relay-supplied metadata worth calling out explicitly rather than
leaving implicit.

## 6. Deposit-address migration — DEFERRED (PR6b)

Migrating the reusable deposit-address templates onto standing streaming intents is deferred to a PR6b
follow-up. In the meantime the H2 guard protects every reusable deposit address, and all deposit families
stay functional. See `migration-loss-inventory.md`.

## 7. Tests

`test/core/Streaming.t.sol` (10): batch flow, `settleStream` full-or-revert (L1), dedup (M1), no-stranding
(H1), `closeStream` C2 anti-rug, keeper reclaim; plus the H2 `NothingToFulfill` cases in
Inbox/InboxAdvanced. Full suite green: forge 630, hardhat 112, jest 42.
