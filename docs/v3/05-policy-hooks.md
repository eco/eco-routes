# PR5 — reward.hooks: keeper-committed delegate hooks on settle/refund

> Adds an opaque, hash-affecting `bytes hooks` to `Reward`. Re-authored onto PR4; mechanically it is
> additive (rename-clean) — the hook machinery reuses PR3's Account delegatecall sandbox.

## 1. `Reward.hooks` (default `Hook[2]`)

`Reward` gains a trailing `bytes hooks`. Decoded on demand as the DEFAULT `abi.encode(Hook[2])` where
`Hook { address target; bytes data; }`:

- index 0 = the **reward hook** — run after a successful `settle`.
- index 1 = the **refund hook** — run after a `refund`.

Empty `hooks` (`length == 0`) means NO hooks — the common case, short-circuited without an external call.
A slot with `target == address(0)` is skipped. `hooks` is HASH-AFFECTING (`rewardHash` → `intentHash`),
so it is keeper-committed and solver-inspectable before anyone fulfills; a hostile hook only makes the
intent unattractive (self-harm), exactly like the committed `route.runtime`. It flows everywhere as opaque
bytes via `abi.encode(reward)`; only the ERC-7683 `ORDER_DATA_TYPEHASH` needed a manual `,bytes hooks`.

## 2. `Account.runHook` (reuses the execute sandbox)

`Account.runHook(bytes hooks, uint256 index)` (`onlyPortal`) mirrors `execute`: it decodes `Hook[2]`,
sets `_IN_EXECUTE_SLOT` to the hook target (so the gated `fallback` forwards in-flight callbacks to it),
`delegatecall`s `Hook.target` with `Hook.data` — so the hook runs AS the intent's own Account
(`address(this)` == the account, same sandbox as the route runtime) — and clears the slot. The heavy
decode/delegatecall lives in the Account (~18 KB headroom), keeping the tight Portal small.

## 3. CEI-LAST, best-effort invocation

`IntentSource._settle` runs the reward hook LAST — after the claimant is paid, the residual swept to the
keeper, and the status set to `Withdrawn`. `_refund` runs the refund hook after the escrow is returned and
the status set to `Refunded`. Both wrap `runHook` in `try/catch` and emit `HookReverted(intentHash,
index)` on failure. Because the `abi.decode` lives INSIDE `runHook` (behind the catch), a malformed
`hooks` is caught too. So a reverting OR malformed hook can NEVER strand an already-paid solver or lock a
keeper's refund — the money effects are committed and irreversible before the hook runs.

## 4. No reentrancy guard (deliberate)

CEI + terminal status + drained account + `onlyPortal` + per-intent Account isolation close the
double-spend surface:
- A hook that reenters `settle`/`refund` of THIS intent reverts on the terminal status (no double-pay).
- A hook cannot re-drive the account's own `runHook`/`execute`: it runs AS the account, so `msg.sender`
  to `runHook` is the account, not the Portal → `onlyPortal` blocks it (caught).
- A hook cannot touch another intent's escrow: it runs AS its own account, which has no allowance over
  any other per-intent account (transferFrom reverts, caught).

## 5. Size

Portal / PortalTron = 23,536 B (headroom 1,040) at `optimizer_runs = 20,000` (unchanged from PR4).

## 6. Tests

`test/core/PolicyHooks.t.sol` (12) + shared `test/core/HookHelpers.sol`: reward/refund hook runs as the
account, zero-target skip, empty-hooks default, best-effort failure (reverting + malformed →
`HookReverted`, money still moves), reentrancy containment, per-intent isolation, `runHook` `onlyPortal`.
Full suite green: forge 620, hardhat 112, jest 42.
