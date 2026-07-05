# Migrating from v2 (main) to v3

> The full user-facing upgrade story: what changed in the structs, the renames, and the new models. For
> the reading order of the design docs see [`00-overview.md`](./00-overview.md); for deliberate narrowings
> see [`migration-loss-inventory.md`](./migration-loss-inventory.md).

## 1. Struct changes

### Route
```solidity
// v2
struct Route { bytes32 salt; uint64 deadline; uint64 source; uint64 destination;
               address inbox; TokenAmount[] tokens; Call[] calls; }
// v3
struct Route { bytes32 salt; uint64 deadline; address portal; address keeper;
               address runtime; bytes payload; TokenAmount[] minTokens; }
```
- `inbox` → `portal` (the combined contract).
- `calls[]` → `runtime` + `payload`. Execution is now a single `delegatecall` into a keeper-chosen
  runtime with an opaque payload; `MulticallRuntime` reproduces the old `Call[]` behavior (its payload is
  `abi.encode(Call[])`).
- `tokens[]` → `minTokens[]`. These are a **solver INPUT floor**, not an output guarantee (see §4).
- new `keeper` — the destination-side Account owner (authenticates `executeAsOwner` on the destination,
  which does not have the `Reward`). Distinct from `reward.keeper` (may differ cross-VM).
- `source`/`destination` moved OUT of `Route` and up to `Intent` (see below).

### Reward
```solidity
// v2
struct Reward { uint64 deadline; address creator; address prover; address nativeAmount?;
                TokenAmount[] tokens; }
// v3
struct Reward { uint64 deadline; address keeper; address prover;
                RewardToken[] tokens; bytes hooks; }
```
- `creator` → `keeper`.
- fixed `TokenAmount` rewards → `RewardToken{token, rate, flat}` **legs** (see §3).
- native is no longer a separate field — it folds in as a `RewardToken` leg with `token == address(0)`.
- new `hooks` — opaque `bytes` (default `abi.encode(Hook[2])`: a post-settle reward hook and a post-refund
  refund hook).

### Intent
```solidity
// v3
struct Intent { uint64 source; uint64 destination; Route route; Reward reward; }
```
- `source`/`destination` are now top-level and are folded into the intent hash (Model C, §5).

### Hashing
```
routeHash       = keccak256(abi.encode(route))
rewardHash      = keccak256(abi.encode(reward))
intentHash      = keccak256(abi.encodePacked(uint64 source, uint64 destination, routeHash, rewardHash))
fulfillmentHash = keccak256(abi.encode(intentHash, claimant, fulfilled))
```
`intentHash` now commits `source`+`destination` — a v2 hash will NOT match a v3 hash even for the "same"
intent. Off-chain tooling must recompute (see the TS SDK in [`08`](./08-deploy-and-release.md)).

## 2. Renames (Vault→Account, Prover→Policy, creator→keeper)

| v2 | v3 |
|----|----|
| `Vault` / `IVault` / `VaultDeployer` | `Account` / `IAccount` / `AccountDeployer` |
| `contracts/vault/*` | `contracts/account/*` (+ `contracts/tron/AccountTron.sol`) |
| `Prover` / `HyperProver` / … | `Policy` / `HyperPolicy` / … |
| `Route.creator`, `Reward.creator` | `Route.keeper`, `Reward.keeper` |
| `NotCreatorCaller` etc. | `NotKeeperCaller` etc. |

The rename is branding for the ephemeral/streaming **"eco accounts"** model: `Vault` implied static
custodial escrow; `Account` signals a general per-intent identity/execution primitive.

## 3. Reward legs (rate + flat) vs fixed amounts

v2 paid a fixed `TokenAmount` per reward token. v3 pays per-leg:

```
payout_j = flat_j + rate_j * provided_j / WAD          (WAD = 1e18)
```
capped at the escrowed balance. `provided_j` is what the solver actually delivered for the paired
`minTokens` leg. A `rate` of one WAD is 1:1 with provided input; a pure `flat` leg (rate 0) is a fixed
tip (e.g. `{address(0), 0, gasAmount}` for a native gas reward). This lets one funded intent serve a
range of fill sizes and scales the reward with the solver's actual contribution.

## 4. minTokens: an INPUT floor, not an output guarantee

v2's `route.tokens[]` were measured as a recipient balance-delta (an OUTPUT guarantee). v3's
`route.minTokens[]` are the minimum the **solver must provide as input**; the solver may provide more, and
`fulfilled[j] = provided[j]`. There is **no on-chain output guarantee** — delivery correctness rests
entirely on the keeper-committed `runtime`/`payload` being honest, which the solver inspects before
filling. This is a deliberate, signed-off narrowing (see loss inventory). Reward-conservation still
protects the solver's escrow from a malicious runtime during same-chain execution.

## 5. Unopinionated core: no recipient, no sweep, keeper + payload

v2 delivered route output to a `route.recipient` and swept leftovers. v3 removes both:
- **No `recipient`.** There is no protocol-level delivery target.
- **No auto-sweep.** Unconsumed solver input stays in the intent's own Account.
- **Keeper retrieval.** `route.keeper` (destination) / `reward.keeper` (source) retrieve funds later via
  `executeAsOwner(runtime, payload)` — any "delivery" is expressed in the payload, not the protocol.

> Note: a two-owner model with `route.recipient` + a `rescueDestination` path existed BRIEFLY mid-develop
> and was then REMOVED by the unopinionated-core decision. `route.keeper` is the sole destination
> authority now; there is no recipient role.

### Model C dual Account (source-in-hash)
The per-intent Account salt is chain-parameterized: `keccak256(abi.encode(intentHash, roleChainId))` where
`roleChainId` is `intent.source` for the escrow account and `intent.destination` for the execution
account. Cross-chain these are two distinct addresses (escrow on source, execution on destination);
same-chain (`source == destination`) they collapse to ONE. This fixes the A→B vs B→B account confusion
and cross-chain replay by construction.

## 6. Streaming intents & schedule policies

- **Streaming** ([06](./06-streaming-and-deposits.md)): a standing, re-fulfillable intent settled by a
  content-addressed `StreamingPolicy`; per-fulfillment slices proven in batches, paid full-or-revert.
- **Schedule policies** ([07](./07-schedule-policies.md)): `VestingPolicy`/`MilestonePolicy`/
  `DutchDecayPolicy` gate release over time/milestones/decay. Standalone contracts (no Portal bytecode).

## 7. What a v2 integrator must change

1. Rebuild intents with the v3 structs (keeper, minTokens, runtime/payload, source/destination on Intent,
   reward legs, hooks).
2. Recompute hashes and predicted Account addresses (source-in-hash; use the v3 SDK).
3. Replace `recipient`-based delivery with a `runtime`+`payload` (e.g. `MulticallRuntime` +
   `abi.encode(Call[])`), and plan keeper-side retrieval of any leftover.
4. Name a `Policy` (not a Prover) in `reward.prover`; for same-chain use `fulfillAndSettle`.
5. Solvers: supply route input capital (no zero-capital flash) and inspect the runtime/payload since there
   is no on-chain output guarantee.
