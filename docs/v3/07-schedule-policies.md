# PR7 — schedule policies (Vesting / Milestone / DutchDecay)

> Standalone settlement-schedule policies with their OWN size budget — no Portal bytecode change.
> Re-authored onto PR6; mechanically rename-clean (they resolve the escrow Account via the Portal's
> `accountAddress`, consume the same streaming batch machinery, and speak Model C vocab).

## 1. What they are

Three concrete policies over shared bases (`ScheduledPolicy`, `StreamingSchedulePolicy`):

- **VestingPolicy** — linear/continuous vesting: the releasable amount grows with time between a start and
  an end.
- **MilestonePolicy** — discrete milestone unlocks: fixed tranches release at committed timestamps.
- **DutchDecayPolicy** — a decaying schedule (e.g. a Dutch-auction-style payout curve over time).

Each is a standalone contract (its own EIP-170 budget, well under the ceiling — no impact on the Portal,
which stays 23,649 B), exposes its own `getProofType`, and supports same-chain and cross-chain settlement
through the base policy machinery. The schedule parameters are committed in `reward.hooks`-style opaque
data / the reward and are keeper-inspectable.

## 2. L1 lesson — advance the ledger by PAID, not entitled

The monotonic released-ledger is advanced by the amount actually PAID (capped at the Account's live
balance), NOT by the entitled amount. So an under-funded intent's shortfall is never forfeited: once the
keeper tops the Account up, the remaining entitlement becomes releasable. The Account's
`withdrawStream` pays each slice in full or reverts (never partially consumes a batch), so the ledger and
the balance stay consistent.

## 3. Size

No Portal change (23,649 B, unchanged from PR6). The policies are separate deployments: VestingPolicy
8,795 B, MilestonePolicy 9,223 B, DutchDecayPolicy 6,188 B — all comfortably under 24,576.

## 4. Tests

`test/core/{VestingPolicy,MilestonePolicy,DutchDecayPolicy}.t.sol` (13 tests): schedule math, the L1
paid-not-entitled ledger (top-up recovery), and settlement. Full suite green: forge 643, hardhat 112,
jest 42.
