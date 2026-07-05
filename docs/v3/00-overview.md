# Eco Routes v3 — overview & reading order

> Umbrella for the v3 reauthoring. v3 is delivered as **8 stacked PRs**, each building on the previous.
> Read them in order; each PR's design doc is linked below. The user-facing upgrade story from v2 is in
> [`migration-from-v2.md`](./migration-from-v2.md); the list of deliberate narrowings is in
> [`migration-loss-inventory.md`](./migration-loss-inventory.md); deploy + release + SDK is
> [`08-deploy-and-release.md`](./08-deploy-and-release.md).

## What v3 is

v3 keeps the ERC-7683 cross-chain intent model and the combined **Portal** (source `IntentSource` +
destination `Inbox`) but reshapes three things:

1. **Unopinionated core** — the protocol no longer delivers to a `recipient` or auto-sweeps. An intent
   names a `runtime` + opaque `payload`; a per-intent **Account** (renamed from Vault) executes the
   payload by `delegatecall`. Leftover input stays in the Account; the **keeper** retrieves it later.
2. **Reward legs, not fixed amounts** — rewards are `rate`+`flat` legs paired to a `minTokens` **input
   floor**; the reward scales on what the solver actually provided.
3. **Policies, not provers** — the settlement/proof surface is a `Policy` (renamed from Prover). Each
   transport (`Hyper`/`LayerZero`/`Meta`/`CCIP`/`Polymer`) is BOTH transport and settlement in one
   contract; schedule policies (`Vesting`/`Milestone`/`DutchDecay`/`Streaming`) add release schedules.

## The 8 PRs, in reading order

| PR | Doc | What it does |
|----|-----|--------------|
| 1 | [01 — policy owns fulfillment](./01-policy-owns-fulfillment.md) | Moves destination fulfillment storage out of `Inbox` into the policy. `fulfill(...)` names its policy; the policy records the fulfillment (one-shot, `onlyPortal`) and builds/dispatches its own proof. |
| 2 | [02 — reward legs & policy](./02-reward-legs-and-policy.md) | Replaces fixed reward amounts with `rate`+`flat` **reward legs** paired to `route.minTokens` (solver **input** floor). Hash-only proof facts (`ProofData{destination, fulfillmentHash}`), preimage-gated settle, `Account.withdraw` consults `IPolicy.previewRelease` (view). Repo-wide **Prover→Policy** and **Vault→Account** / `.creator`→`.keeper` renames. |
| 3 | [03 — dual account + runtime](./03-dual-vault-runtime.md) | **Model C**: chain-parameterized dual Account salt `keccak(intentHash, roleChainId)` — source (escrow) vs destination (execution), collapsing to one on same-chain. `route.calls[]` → `(runtime, payload)`; `Account.execute` delegatecalls the runtime under an in-execute guard. Adds `intent.source` to the hash. `MulticallRuntime` is the default runtime. |
| 4 | [04 — same-chain & gates](./04-same-chain-and-gates.md) | Reward-conservation postcondition (a runtime cannot touch reward escrow), `block.chainid` gates (`WrongSourceChain`/`WrongDestinationChain`), `fulfillAndSettle` one-tx same-chain solve. Destination `executeAsOwner` restricted to cross-chain. |
| 5 | [05 — policy hooks](./05-policy-hooks.md) | Adds `reward.hooks` (opaque `bytes`, default `abi.encode(Hook[2])`): a reward hook post-settle and a refund hook post-refund, `delegatecall`ed by the Account CEI-last via try/catch (a reverting/malformed hook can never revert the committed settle/refund). |
| 6 | [06 — streaming & deposits](./06-streaming-and-deposits.md) | Content-addressed `StreamingPolicy` for standing (re-fulfillable) intents; source-side settle/close; `H2` `NothingToFulfill` anti-poison guard protecting reusable deposit addresses; `Account.withdrawStream` (full-or-revert per slice). |
| 7 | [07 — schedule policies](./07-schedule-policies.md) | Standalone `VestingPolicy`/`MilestonePolicy`/`DutchDecayPolicy` (own size budget, no Portal bytecode). Released-ledger advances by amount **paid** (balance-capped), never entitled, so an under-funded shortfall stays recoverable after top-up. |
| 8 | [08 — deploy & release](./08-deploy-and-release.md) | `scripts/DeployV3.s.sol` (deterministic CREATE2/CREATE3, the **C1** right-aligned self-reference fix), release-pipeline retarget to the renamed contract set, and the TS SDK port. |

## Vocabulary map (v2 → v3)

| v2 | v3 | note |
|----|----|------|
| `Vault` | `Account` | per-intent identity/execution primitive, not just static escrow |
| `Prover` | `Policy` | proof + settlement surface |
| `Route.creator` / `Reward.creator` | `Route.keeper` / `Reward.keeper` | the owner/retrieval authority |
| fixed `Reward` amounts | `RewardToken{rate, flat}` legs | scales on provided input |
| `route.recipient` + auto-sweep | (removed) | unopinionated core: keeper retrieves via payload |
| `route.calls[]` | `route.runtime` + `route.payload` | delegatecall execution |
