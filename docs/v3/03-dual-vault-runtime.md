# PR3 — Model C dual account (source-in-hash) + delegatecall runtime execution

> Re-authored onto the PR2 base (minTokens input-floor, unopinionated core, `Vault`→`Account`,
> `creator`→`keeper`). PR3 adds the intent `source` to the hash, makes the per-intent **Account**
> chain-parameterized (so the source-side escrow and the destination-side execution are address-separated
> for a cross-chain intent and collapse to one address same-chain), and moves route execution **into the
> Account** via `delegatecall` to a keeper-committed `runtime(payload)` (default runtime:
> `MulticallRuntime`). The standalone `Executor` is retired.

## 1. Model C — `source` in the hash + chain-parameterized dual account

### 1.1 `source` in the intent hash
`intentHash = keccak256(abi.encodePacked(uint64 source, uint64 destination, routeHash, rewardHash))`
via `IntentLib.hashIntent`. Every hash site (IntentSource, Inbox, the ERC-7683 adapter, LocalPolicy,
`BasePolicy.challengeIntentProof`, the deposit templates) goes through it. Adding `source` makes an
`A->B` intent distinct from an `A'->B` intent (kills cross-chain replay double-claim). The origin chain
id is carried in the ERC-7683 `originData` so the destination fill re-derives the same hash. `Intent`
gains a leading `source` field.

### 1.2 Chain-parameterized Account salt (`AccountDeployer`)
The per-intent Account is an ERC-1167 clone deployed via CREATE2 with a **role-aware** salt:

```
accountSalt = keccak256(abi.encode(intentHash, roleChainId))
//   source / escrow account:      roleChainId == intent.source
//   destination / execution:      roleChainId == intent.destination
```

- **Cross-chain (`source != destination`)**: two distinct addresses — the escrow lives at
  `keccak(intentHash, source)` (source chain), any execution leftover at `keccak(intentHash, destination)`
  (destination chain). Source-side ops can never reach the destination account (the account-confusion
  attack dissolves by construction).
- **Same-chain (`source == destination`)**: the two salts are identical ⇒ **ONE** Account at one address
  that holds escrow AND executes.

Both Portal halves inherit the shared `AccountDeployer` (constructor args supplied once by the concrete
`Portal`/`PortalTron` via C3 linearization). `intentAccountAddress(...)` returns the **source/escrow**
account. Every source-side op (fund / settle / refund / recoverToken / `executeAsOwner`) resolves its
account with `roleChainId = intent.source`; the destination fulfill uses `roleChainId = block.chainid`
(== `intent.destination`).

## 2. Route: `runtime` + `payload` (delegatecall execution)

`Route.calls[]` is replaced by `address runtime; bytes payload` (the `Call` struct moves to
`IRuntime.sol`). The Account's `execute(runtime, payload)` `delegatecall`s the runtime, so it runs in the
**Account's** context — `address(this)`, balances and approvals are the Account's — spending the staged
inputs directly. The default runtime, `MulticallRuntime`, decodes `payload` as `abi.encode(Call[])`,
keeps the v2 `Executor`'s EOA guard (`CallToEOA`) and revert-bubbling (`CallReverted`), and is stateless
(safe to share across every intent). Because `runtime` is committed in the `routeHash` (hence the
`intentHash`), the intent commits to the exact code that runs against the Account holding its funds.

**Gated fallback / in-execute slot.** `Account.execute` stores the runtime address in a HIGH hashed slot
(`_IN_EXECUTE_SLOT`) for the duration of the delegatecall. A callback re-entering the Account's address
lands in the gated `fallback`, which forwards to that same runtime **only while execute is on the stack**;
outside execute the slot is zero and it reverts `FallbackNotInExecute` — closing the
unauthenticated-delegatecall drain vector. `receive()` stays open for bare native (counterfactual
funding, WETH unwraps, native swap proceeds).

## 3. Destination fulfill (minTokens input floor, NO sweep)

`fulfill(source, intentHash, route, rewardHash, claimant, providedAmounts, prover)`:
1. re-derive `intentHash` with `hashIntent(source, block.chainid, routeHash, rewardHash)` and check it;
2. enforce the solver **input** floor per leg (`providedAmounts[j] >= route.minTokens[j].amount`,
   `InsufficientTokens` otherwise); `fulfilled[j] = providedAmounts[j]`;
3. stage each ERC20 leg from the solver **onto the destination Account** and forward the native leg as the
   `execute` value;
4. `IAccount(account).execute{value: nativeProvided}(route.runtime, route.payload)` — run the program;
5. commit the hash-only fact `keccak256(abi.encode(intentHash, claimant, fulfilled))` into the named
   prover (one-shot gate = replay guard).

The core is **unopinionated**: there is no `recipient`, no measured output floor, and **no sweep**.
Delivery is the payload's job (any beneficiary lives inside a call's calldata). Any input the runtime does
not consume simply **stays in the destination Account** — leftover stays with the intent — for
`route.keeper` to retrieve later.

## 4. `executeAsOwner` — two independent owner authorities

Leftover / stray funds are retrieved by the keeper, per role:

- **Source (escrow) account — `IntentSource.executeAsOwner(intent, runtime, payload)`**: gated by
  `msg.sender == reward.keeper` **and** `block.chainid == intent.source`. Anti-rug escrow/proof lock:
  while a `Funded` intent's reward is still live (has legs AND before the deadline) or already carries a
  valid destination proof, it reverts `AccountLocked` (a solver may be owed the escrow). Permitted for
  `Initial` (nothing escrowed), `Withdrawn`/`Refunded` (escrow gone), or `Funded` once the escrow is free
  (past deadline, no live legs, no valid proof).
- **Destination (execution) account — `Inbox.executeAsOwner(source, route, rewardHash, runtime, payload)`**:
  gated by `msg.sender == route.keeper`. The account is derived with `roleChainId = block.chainid`, so it
  only ever reaches the local (this-chain) execution account — structurally the
  `block.chainid == intent.destination` gate. `route.keeper` is the destination-side owner (the
  destination sees only the route + opaque `rewardHash`, never `reward.keeper`).

> Same-chain caveat: when `source == destination` the escrow and execution accounts collapse, so the
> destination `executeAsOwner` (gated by `route.keeper`, which cannot introspect the reward) could reach
> live escrow. The escrow-preservation guarantee for that collapsed case is the **reward-conservation
> postcondition added in PR4** (snapshot escrow-token balances around any Account execution and revert if
> they drop). PR4 must wrap both the fulfill execute path and this destination `executeAsOwner`.

## 5. `recoverToken`

`recoverToken(source, destination, routeHash, reward, token)` (kept from PR2, now source-role-aware):
rescues a non-reward token stuck in the **source escrow** account to `reward.keeper`; reverts
`InvalidRecoverToken` for a reward-leg token or the zero address.

## 6. Retired / moved

- `Executor` + `IExecutor` deleted (execution merged into the Account).
- `PortalTron` and `AccountTron` moved to `contracts/tron/`.
- New: `contracts/account/AccountDeployer.sol`, `contracts/interfaces/IRuntime.sol`,
  `contracts/runtime/MulticallRuntime.sol`.

## 7. Size budget

Portal / PortalTron ≈ 24,380 bytes at `optimizer_runs = 1,000,000` (< 24,576). The PR2 minTokens +
unopinionated-core reclaim absorbed PR3's runtime-execution additions, so no optimizer lowering is
needed.

## 8. Tests

`test/core/DualVaultRuntime.t.sol` (Model C address separation + same-chain collapse + confusion-attack
prevention, gated fallback, `recoverToken`, `executeAsOwner` escrow/proof lock) and
`test/core/MulticallRuntime.t.sol` (batch execution, EOA guard, revert bubbling) replace the retired
`Executor.t.sol`. Full suite green: forge 589, hardhat 112, jest 42.
