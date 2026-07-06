# PR11 — same-chain zero-capital flash (one-shot + standing pools)

**Branch:** `v3/11-same-chain-flash` (base `v3/10-erc7683-adapter-split`)

## Goal

Restore v2's **zero-capital same-chain flash** — lost in the v3 redesign and recorded in the
migration-loss inventory ("No zero-capital same-chain flash") — as **two standalone v3 policies**, with
**ZERO diffs to the core** (Portal/IntentSource/Inbox/Account/existing policies untouched):

- `contracts/prover/SameChainFlashPolicy.sol` — the ONE-SHOT flash (`flashFulfill`): v2 parity, one
  intent, one fulfill, terminal settle.
- `contracts/prover/StreamingFlashPolicy.sol` — the STANDING-POOL flash (`flashSlice`): a replenishable
  pool intent drawn down in successive variable-size slices, status stays `Funded` between slices.
- `contracts/interfaces/IFlashSolver.sol` — the swap-callback surface a solver implements to convert the
  advance into the route's input legs mid-session.

## The v2 mechanism being restored

v2's `LocalProver.flashFulfill` (main branch, `contracts/prover/LocalProver.sol:175-247`) was a
**withdraw-BEFORE-fulfill** flow: it pinned a `_flashFulfillInProgress = intentHash` session flag, called
`Portal.withdraw` — which consulted `provenIntents`, whose "Case 3" (`LocalProver.sol:99-104`) answered
**with the prover itself as claimant** while the session flag matched (SELF-VOUCHING) — so the reward
escrow landed on the prover BEFORE the route ran. The prover then funded the route inputs out of that
advance, called `Portal.fulfill` with the REAL claimant, and forwarded every leftover balance to the
claimant as the solver's margin. Any misalignment reverted the whole transaction. The solver fronted
**zero capital**; the fee was whatever the reward exceeded the route inputs by.

v3's first pass dropped this deliberately: rewards became `fulfilled[]`-scaled, settlement became gated
on the fulfillment-hash preimage, and PR4's reward-conservation postcondition forbids the runtime from
consuming escrow — so `LocalPolicy.flashFulfill` degraded to fulfill-then-settle (capital-EFFICIENT, not
capital-FREE; see the PR2 note in `contracts/prover/LocalPolicy.sol`).

## Why zero core diffs suffice: the oracle seam

v3's settlement layer already trusts the committed policy at three seams, and all three are wide enough
to carry the v2 session trick:

1. **`IntentSource._settle` trusts `IPolicy(reward.prover).provenIntents(intentHash)`**
   (`contracts/IntentSource.sol:614`). Its checks are: the fact's `destination` matches, and
   `IntentLib.fulfillmentHash(intentHash, claimant, fulfilled) == proof.fulfillmentHash`. A policy that
   momentarily *serves a synthetic fact committing itself as claimant* makes the generic `settle` release
   the escrow to the policy — exactly v2's Case-3 self-vouching, but through the hash-only preimage gate.
2. **`Account.withdraw` trusts `IPolicy(reward.prover).previewRelease`** (`contracts/account/Account.sol:128`)
   for the per-leg owed amounts (balance-capped, residual swept to the keeper).
3. **`IntentSource.settleStream` trusts `IStreamingPolicy(reward.prover).consumeStreamClaims`**
   (`contracts/IntentSource.sol:876`) for an opaque payout table that `Account.withdrawStream` pays
   full-or-revert, with **no status transition** (the intent stays `Funded`).

The committed `reward.prover` is part of the reward hash: a keeper who names a flash policy has opted
into its settlement semantics, exactly as with any other policy. No Portal, Inbox, Account, or existing
policy changed in this PR (`git diff` gate: scripts + new files only).

## SameChainFlashPolicy — the one-shot session

`flashFulfill(protocolVersion, route, reward, claimant, solverData)`, `nonReentrant`:

1. **SESSION OPEN** — derive `intentHash` (same-chain: `_CHAIN_ID` on both sides), pin
   `_sessionFact = fulfillmentHash(ih, THIS_POLICY, planned)` and
   `_sessionExpectedFact = fulfillmentHash(ih, claimant, planned)`, where `planned[j] =
   route.minTokens[j].amount` — one-shot intents commit the **exact input floors** as the `fulfilled[]`.
2. **ADVANCE** — call the untouched generic `Portal.settle(…, claimant = THIS_POLICY, planned)`.
   `provenIntents` serves the session fact (only while no real fact exists), the preimage check passes,
   the status flips to **`Withdrawn`** (terminal — no path can release the escrow again, mid-session or
   ever), the Account pays the policy `min(rate·planned + flat, balance)` per leg, and sweeps the
   residual to the keeper.
3. **FUND + FULFILL** — the advance funds the route inputs: **direct mode** (`solverData` empty, the
   same-token/deposit case) approves the Portal for the floors out of the advance; **swap mode**
   (`solverData` non-empty) hands the measured advance to the caller, invokes
   `IFlashSolver.onFlashAdvance`, then pulls the exact ERC20 input legs back (revert = whole flash
   unwinds, advance included). Then the untouched `Portal.fulfill` runs with the **REAL claimant**.
   `recordFulfillment` is STRICT during a session: only `(sessionIntentHash, sessionExpectedFact)` is
   accepted — any interleaved record reverts everything.
4. **MARGIN + SESSION CLOSE** — every remaining reward-leg ERC20 balance plus the native balance is
   forwarded to the claimant (native best-effort, v2 parity), and the session resets to the non-zero
   `_NO_SESSION` sentinel (v2's cheap non-zero→non-zero flip).

Outside a session the policy behaves exactly like `LocalPolicy` (one-shot hash-only record store, the
fact IS the proof, standard rate+flat curve), so plain fulfill-then-settle also works against it.

### Fulfill's conservation snapshot is ~0 by construction

`Inbox._fulfill` snapshots the Account's reward-leg balances **before staging inputs**
(`contracts/Inbox.sol:328-339`). Because the advance already emptied the escrow (step 2 paid the policy
and swept the residual), the same-chain snapshot is ~0 and the postcondition (`live >= escrowBefore`) is
trivially satisfied — the withdraw-before-fulfill ordering is precisely what makes the flash coexist with
PR4's escrow protection instead of fighting it.

## StreamingFlashPolicy — standing pools, full-pool advance

A pool intent's **reward legs ARE the pool**: pure rate legs (`flat == 0`, `rate != 0`) paired 1:1 with
the input legs, funded and topped up by **direct transfers** to the deterministic escrow Account, with
effectively-infinite deadlines (`type(uint64).max`) so the permissionless post-deadline `refund` can
never terminate the pool — `closeStream` is the sole exit.

`flashSlice(protocolVersion, route, reward, claimant, solverData)`, `nonReentrant`:

1. **Read the pool, derive the slice** — `pool[j]` = the escrow Account's balance of reward leg `j`
   (the Account address read through the Portal's `accountAddress(ih, CHAIN_ID)`; same-chain, the escrow
   and execution Accounts collapse to one). Then:

   ```
   slice[j] = floor(pool[j] * WAD / rate[j])        // rounds DOWN — margin never negative
   require(slice[j] >= route.minTokens[j].amount)   // the minTokens floor = the dust guard
   ```

   Rearranged: `slice[j]·rate[j]/WAD <= pool[j]`, so in the same-token case the advance always covers
   the staged slice and `margin[j] = pool[j] − slice[j] >= 0`.
2. **SESSION OPEN + FULL-POOL ADVANCE** — pin the expected real-claimant fact
   (`fulfillmentHash(ih, claimant, slice)`) and the payout table `abi.encode([THIS_POLICY], [pool])`,
   then call the untouched `Portal.settleStream`. The **session-scoped, Portal-only, consume-ONCE**
   `consumeStreamClaims` serves that pinned table exactly once; `Account.withdrawStream` pays the WHOLE
   pool to the policy full-or-revert. The **status stays `Funded`** and the escrow Account is **EMPTY**.
3. **FUND + FULFILL** — stage `slice` back as the route input (direct from the advance, or via the
   `IFlashSolver` swap callback) and run the real `Portal.fulfill` with the real claimant.
   `recordFulfillment` during the session accepts only the expected fact, **exactly once**, and the
   slice is **CONSUMED AT BIRTH** — the advance already paid it, so it never enters an unsettled store
   (only `sliceCount` + events remain, as the audit trail) and can never be settled again.
4. **MARGIN + SESSION CLOSE** — `pool − slice` per leg (plus any native remainder) to the claimant.

### Why balance-reading runtimes are safe here

A standing pool's slice size varies with the pool, so the committed `route.payload` cannot embed
amounts — it commits **CONFIG only** (e.g. "sweep this token to this recipient"), and the runtime reads
the Account balance at execution time. That is safe **by construction**, not by the conservation check:

1. **The Account holds only the staged `slice`.** The full-pool advance (step 2) empties the escrow
   Account of every reward-leg token *before* `_fulfill` stages `slice` back into it, so the only balance
   a balance-reading runtime can see — and the most it can possibly burn — is exactly `slice`.
2. **The margin never enters the Account.** `pool − slice` stays on the policy for the whole `fulfill`
   and is forwarded to the claimant only after it returns, so no runtime can reach the solver's margin.
   The `slice` itself is the keeper's own pool money, so a misbehaving runtime that wastes it is
   keeper self-harm bounded to one slice (`route.runtime` is committed in the intent hash — the pool's
   funder chose it; for the PR12 deposit templates it is template-authored, so no third party can
   supply it at all).

Note the reward-conservation postcondition (`live >= escrowBefore`) is **vacuous** in this path:
`escrowBefore == 0` after the advance, so `live >= 0` always holds. The safety argument above does
**not** lean on it — it is the empty-Account-then-stage-`slice` construction that bounds consumption.

### Everything is inert outside a session

| Surface | Inside the session (own tx only) | Outside a session |
| --- | --- | --- |
| `provenIntents` | zero fact (nothing consults it) | **zero fact** — generic `settle` can never match a preimage; the pre-deadline `refund` gate never sees a valid proof |
| `consumeStreamClaims` | pinned `[policy → pool]`, Portal-only, consume-ONCE (`AdvanceAlreadyConsumed` on a re-entry) | **reverts** `NotFlashSession` — a generic `settleStream` can never move money |
| `recordFulfillment` | expected real-claimant fact only, once (`UnexpectedSessionFulfillment` / `IntentAlreadyFulfilled`) | **reverts** `NotFlashSession` — `flashSlice` is the ONLY fulfillment path; a plain fulfill against a pool intent unwinds whole (blocks plain-fulfill poisoning) |
| `hasUnsettledFulfillment` | false | **false** — slices are consumed at birth, so the keeper's `closeStream` (pool refund: the reward legs ARE the pool tokens) is always available between slices |
| `markClosed` | — | Portal-only; terminal — `flashSlice` reverts `StreamClosed` forever after |
| `recordBatch` | — | always reverts (no cross-chain relays exist for an atomic flash pool) |

### One-shot `provenIntents` precedence (the session core)

| Priority | Fact served | When |
| --- | --- | --- |
| 1 | the REAL stored fact | always wins once recorded |
| 2 | the synthetic session fact (policy as claimant over the floors) | only during an open session for exactly this hash — observable only inside the policy's own atomic `nonReentrant` transaction |
| 3 | the zero fact | otherwise |

A **pre-recorded real fact BLOCKS flash** (`IntentAlreadyFulfilled`): recording one requires an actual
`fulfill` — full input capital + route execution — so it is at worst a competing honest fulfillment
(settleable with its own preimage) or a **griefing DoS of the flash path only**, never theft.

## The fee is the reward-leg rate spread — no payload fees

The solver's compensation is **protocol-enforced**, priced entirely in the committed reward curve:

- one-shot: `margin = min(rate·planned + flat, escrow) − planned` (per paired leg, same-token case) plus
  whatever residual the keeper over-escrowed beyond the owed amount goes back to the keeper;
- pool: `margin[j] = pool[j] − floor(pool[j]·WAD/rate[j])` — a `rate` of `1.25e18` is a 25% spread.

There are **deliberately NO payload-embedded fees**: the route payload delivers the slice, full stop. A
pool leg carrying `flat != 0` reverts (`FlatLegUnsupported` — a per-slice flat cannot be expressed under
the full-pool advance), an unpaired extra reward leg reverts (`UnpairedLegs` — it would leak to the
claimant as pure margin), and `rate == 0` reverts (`ZeroRateLeg`).

## Griefing residuals (documented, no theft)

- **Pre-recorded fact blocks one-shot flash** — DoS of the flash path only (see precedence above). The
  keeper is never locked: past `reward.deadline` the reward is always refundable (hash-only anti-lock).
- **A fulfillment committing THIS POLICY as claimant** strands its settle payout on the policy; stranded
  balances become the next flash caller's bonus margin (v2 parity, `LocalProver` Case-1 analogue).
- **Native margin is best-effort** (v2 parity): a claimant that rejects native leaves it on the policy
  for the next flash caller.
- **A keeper's reward hook** (committed in the reward hash, runs mid-advance under `settle`) can at
  worst make its own intent un-flashable (e.g. by pre-recording the expected fact) — solver self-harm
  avoidance is simulation, as with any committed hook/runtime.
- **Front-running** — `flashFulfill`/`flashSlice` are permissionless; standard MEV behavior in intent
  systems (v2 carried the same warning).
- **Mid-session `refund` by a malicious runtime.** `Portal.settle`/`fulfill`/`refund` carry no reentrancy
  guard, and the session's synthetic fact is live for the whole `fulfill` (it is served until
  `recordFulfillment` runs, which `Inbox._fulfill` does *after* `execute`). A `route.runtime` could
  therefore, mid-`fulfill`, call `Portal.refund` for its own session intent — the synthetic fact makes
  `_validateRefund` take the "already settled: allow" branch (status is `Withdrawn`), draining the just-
  staged `slice`/floors. This is **keeper self-harm only**: `route.runtime` is committed in the intent
  hash (the pool's / intent's own funder authored it), `refund` routes exclusively to `reward.keeper`,
  and — critically — the escrow was already advanced out to the policy, so the drain hits only the
  keeper's own re-staged input, never the solver (whose margin sits on the policy) and never any other
  intent (`provenIntents` serves a fact only for the single `_sessionIntentHash`, inside one atomic
  `nonReentrant` tx). For the PR12 deposit templates the runtime is template-authored, so no third party
  can reach this path at all. Same trust model as every v3 runtime/hook; avoidance is simulation.

## Deploy + release

`scripts/DeployV3.s.sol` deploys both policies via CREATE3 (portal-only constructor arg; salts
`SAME_CHAIN_FLASH_POLICY` / `STREAMING_FLASH_POLICY`), gated by `DEPLOY_FLASH_POLICIES` (default true),
**EVM only** — the policies have no Tron `_transferToken` subclass yet (both keep the hook `virtual`,
mirroring why `LocalPolicyTron` exists). `CONTRACT_TYPES` in the semantic-release packager records both.

## What PR12 builds on this

The flash policies are the last settlement primitive the same-chain stack needed: PR12 (deposit
self-service / first-class same-chain flows) can now compose deposit-style intents on top of the
one-shot policy (direct mode IS the deposit case: reward token == input token, the advance funds the
deposit, the spread pays the executor) and recurring keeper-funded flows on top of the standing pool
(top-up == direct transfer; `closeStream` == the product's off-switch), without touching the core or
inventing new settlement seams.

## Tests

`test/core/SameChainFlash.t.sol` + `test/core/StreamingFlash.t.sol` (20 tests): zero-capital lifecycle
end-to-end (direct + swap-callback), variable-size multi-slice pools with direct-transfer top-ups,
closeStream keeper exit, and one adversarial test per hole: session-fact invisibility, pre-recorded-fact
DoS, runtime re-entrancy, mid-session `settle`/`settleStream` double-release, plain-fulfill poisoning,
`consumeStreamClaims` gates, dust floors, round-down margins, deadbeat swap callbacks, and post-close
slicing. Every lifecycle test asserts money conservation: the summed balance deltas across pool account,
policy, solver, claimant, keeper and recipient are zero.
