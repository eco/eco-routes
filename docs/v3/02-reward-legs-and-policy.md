# PR2 — Rate+flat reward legs, min-IN input floor, hash-only facts, and the Prover→Policy rename

> Replace the fixed-amount reward with a **rate+flat legs** model paired to a new **`route.minTokens`**
> input floor. The solver PROVIDES the input (it may provide more than the floor); the reward scales on
> what was **provided**, not on a measured output. Carry the provided-amounts array as a **hash** in the
> cross-chain fact and require the claimant to supply the preimage at settle. Have the **Vault call the
> prover (as a VIEW)** to compute reward amounts on settle. Then do the mechanical **Prover→Policy**
> rename. This keeps `main`'s combined prover architecture (each prover = transport + settlement in one
> contract) and the single-sided Vault + Executor — the transport/policy relay split, the unified
> dual-chain vault, and the runtime are later stages. Stacked on PR1 (`v3/01-policy-storage`). Net-new,
> undeployed, local-only.

## 1. The reward model — rate+flat legs paired to `route.minTokens`

`Reward.tokens` is now a `RewardToken[]` of **legs**, not a `TokenAmount[]` of fixed amounts:

```solidity
struct RewardToken { address token; uint256 rate; uint256 flat; }   // rate is WAD-fixed-point
struct Reward { uint64 deadline; address creator; address prover; RewardToken[] tokens; }
```

`Route` drops the old separate `nativeAmount` + `tokens` input arrays and the `minOut` output floor,
carrying a single `minTokens` list — the solver INPUT floor. The **core is unopinionated** about where
funds go: there is **no `recipient`** and no protocol-level output floor or auto-sweep to one. It adds a
**`creator`** — the owner of the DESTINATION-side vault:

```solidity
struct Route {
    bytes32 salt; uint64 deadline; address portal;
    address creator;                  // owner of the DESTINATION-side vault (leftover / executeAsOwner authority)
    Call[] calls;
    TokenAmount[] minTokens;          // minimum inputs the solver must PROVIDE (may provide more)
}
```

- `route.creator` is the **destination-side vault owner** — the authority that may retrieve the leftover
  and (once vault execution lands in PR3) `executeAsOwner`. It lives in the **Route** because the
  destination only sees the route plus the opaque `rewardHash` and **cannot read `Reward.creator`**, so
  without it the destination has no way to authenticate who owns the vault. It is the **same logical
  entity** as `Reward.creator` (the SOURCE escrow owner) but **MAY be a DIFFERENT address** across a
  cross-VM lane (e.g. a Solana source, an EVM destination). In PR2 it is a **hashed field only** — not yet
  wired to any access control (executeAsOwner is PR3).
- `route.minTokens[j] = (inToken_j, minAmount_j)`: the solver must **provide at least** `minAmount_j` of
  `inToken_j` into the destination execution, and MAY provide more. There is **no on-chain output
  floor** — **delivery is the job of the committed `calls` (the payload)**: any beneficiary address lives
  INSIDE a call's calldata, not in the Route. Any input the calls do not consume is **not stranded and
  not sent to a protocol recipient** — it is moved to the **intent's Vault** so the leftover **stays with
  the intent**, where `route.creator` can retrieve it later. Native folds in as a `minTokens` leg with
  `token == address(0)` (its `amount` is the native forwarded into execution). Enforced strictly
  ascending by token address (dedup + canonical order).
- Reward legs pair **positionally** to `minTokens`: leg `j < minTokens.length` is the reward for input-leg `j`.
  Extra legs `j >= minTokens.length` are **flat-only** (e.g. a native gas reward). The reward token MAY
  differ from the input token — `rate` encodes the conversion.
- **Per-leg reward** = `RewardMath.reward(fulfilled_j, rate_j, flat_j) = mulDiv(fulfilled_j, rate_j, WAD)
  + flat_j`, where `fulfilled_j` is the amount the solver actually **provided** as input (`>= minAmount_j`).
  Always **capped at the vault balance** for that token (`RewardMath.capped`) — never release more than
  escrowed (money-conservation; advance any ledger by PAID, not entitled). "Lower boundary, can provide
  more": a solver that provides more earns proportionally more `rate` reward.
- **v2 parity:** a fixed reward of `amount` of `token` is `{token, rate: 0, flat: amount}`. Native folds
  in as a leg with `token == address(0)` — there is no separate `reward.nativeAmount` anymore.
- `WAD = 1e18`. `MAX_IN_TOKENS = 8`, `MAX_REWARD_TOKENS = 16` bound the loops / the O(n²) uniqueness scan.

### Canonicalization
- `minTokens` MUST be **strictly ascending** by token address (`IntentLib.requireStrictlyAscending`, enforced
  at the destination fulfill). Strictly-ascending dedupes the legs so the provided `fulfilled[]` pairs
  unambiguously with the reward legs. Native (`address(0)`) sorts first. `<= MAX_IN_TOKENS`.
- Reward legs MUST be **unique by token** and `<= MAX_REWARD_TOKENS` (`IntentLib.requireUniqueRewardTokens`,
  enforced at the source `publish`). The route is treated as **opaque bytes** on the source (cross-VM
  compatibility), so the paired-vs-`minTokens` ORDER is a creator-side canonical form; only the route-free
  checks run on-chain source-side, and `minTokens` dedup is enforced at the destination.

## 2. Hash-only cross-chain fact + input-floor enforcement at fulfill

Only `(intentHash, fulfillmentHash)` crosses chains, where

```
fulfillmentHash = keccak256(abi.encode(intentHash, bytes32 claimant, uint256[] fulfilled))
```

- `IProver.ProofData` changed from `{address claimant, uint64 destination}` to
  `{uint64 destination, bytes32 fulfillmentHash}`. `recordFulfillment(intentHash, destination,
  fulfillmentHash)` stores the hash; the wire pairs and the receive side (`_processIntentProofs`,
  `PolymerProver.validate`) carry/store the hash. **The claimant is no longer in the fact** — there is no
  claimant-validity check at proof time (it moved to settle). `challengeIntentProof` keys on the
  fulfillmentHash presence.
- `fulfill`/`fulfillAndProve` take an explicit solver-supplied `uint256[] providedAmounts`
  (index-aligned with `route.minTokens`). `Inbox._fulfill` enforces the **INPUT floor**: for each leg it
  requires `providedAmounts[j] >= route.minTokens[j].amount` (else `InsufficientTokens(token, provided,
  required)`), pulls `providedAmounts[j]` of each ERC20 leg from `msg.sender` into the executor, and
  requires `msg.value >=` the native leg's provided amount (else `InsufficientNativeAmount`). It requires
  `providedAmounts.length == route.minTokens.length` (else `ProvidedAmountsLengthMismatch`). `fulfilled[j] =
  providedAmounts[j]` — the actual input provided (what the reward scales on).
- **There is NO recipient and NO output balance-delta measurement.** Delivery is the calls' job (any
  beneficiary is inside the calls' calldata). After executing the calls,
  `Executor.sweepTo(route.minTokens, intentVault)` moves any input the calls did not consume to the
  **intent's Vault** — leftover stays **with the intent** (the creator retrieves it later) rather than
  being stranded in the shared executor or sent to a protocol-level recipient. The intent Vault address is
  deterministic (CREATE2 keyed on the intent hash) and identical across chains, so the same per-intent
  vault the creator controls on the source chain is addressable from the destination Inbox; the composition
  root (Portal / PortalTron) wires `_predictVault` to `IntentSource._getVault`. The Executor holds **only**
  solver input (never reward escrow — escrow lives in the Vault), so moving its remainder to the Vault can
  never misdirect escrow. `fulfillmentHash` is computed over `fulfilled[] = providedAmounts` and recorded
  into the named prover **after** execution + the vault move; a re-entrant re-fulfill of the same intent
  reverts the whole tx via the prover's one-shot gate, so recording-after-effects cannot double-deliver.
  The excess-native refund to the solver (`Refund.excessNative`) and the fill/fulfillAndProve/prove plumbing
  are preserved. `DestinationSettler.fill`'s `fillerData` now carries `providedAmounts` (`(address prover,
  uint64 source, bytes32 claimant, uint256[] providedAmounts, bytes proverData)`).

## 3. Settlement — preimage verify + Vault-calls-Policy(view)

`IntentSource.withdraw` became:

```solidity
settle(uint64 destination, bytes32 routeHash, Reward reward, bytes32 claimant, uint256[] fulfilled)
```

1. Read `reward.prover.provenIntents(intentHash)`.
2. Keep the wrong-destination `challengeIntentProof` escape hatch.
3. Verify `keccak256(abi.encode(intentHash, claimant, fulfilled)) == fulfillmentHash`
   (`InvalidFulfillmentProof` on mismatch); require `claimant` be a valid EVM address (`InvalidClaimant`).
4. `Vault.withdraw(reward, claimant, fulfilled)` — the **Vault** calls
   `reward.prover.previewRelease(reward, fulfilled)` (a **`view`**, so it is a staticcall — no reentrancy
   surface) for the per-leg amounts, pays each `min(payNow, balance)` to the claimant, and **sweeps the
   residual of each leg token to `reward.creator`**.

`previewRelease(Reward, uint256[] fulfilled) view returns (uint256[] payNow)` is the atomic rate+flat
curve on the policy: paired legs return `fulfilled[j]*rate/WAD + flat`, extra legs return `flat`.

### Funding
Funding iterates `RewardToken[]` legs; the escrow **target per leg is its `flat`**. The source keeps the
route opaque (cross-VM), so it cannot fold in the rate-scaled `minTokens` minimum; the `rate` term is paid
at settle only out of vault balance in excess of the flats, always capped at balance. A fixed same-asset
reward (`rate: 0`) funds and pays exactly `flat` (v2 parity). Guaranteeing a rate payout requires
over-funding — refined when the per-intent escrow budget (Pod) arrives in a later stage. Native leg funded
from `msg.value`. Never-revert clamps, partial-funding `complete=false`, and excess-native refund
conventions are preserved. `refundTo(refundee)` is **restored**; `recoverToken` + `Vault.recover` +
`IntentTokenRecovered` are **kept** (wrong-token rescue, excluding reward-leg tokens). `salt` is **kept**.

### Anti-lock refund (a deliberate, flagged semantics change vs v2)
`_validateRefund`: **after** `reward.deadline` the reward is **always** refundable (unless already
settled), and **before** it a fulfilled-but-unsettled intent must settle (`IntentNotClaimed`) while an
unfulfilled one is not yet refundable (`InvalidStatusForRefund`). This differs from v2, where a *proven*
intent could **never** be refunded: in the hash-only model the source cannot introspect the committed
claimant, so the anti-griefing guarantee (a bad-claimant fulfillment cannot permanently lock the
creator's funds) is preserved by the **deadline** instead. Consequence: a proven-but-unsettled
(incl. cross-chain) intent becomes refundable after the deadline — the solver must settle within the
window `[fulfill, reward.deadline]` (which is strictly after the route deadline). v2's dust-recovery /
repeated-refund after the deadline is preserved.

## 4. Prover → Policy rename (the follow-up mechanical commit)

The settlement/proving abstraction is renamed repo-wide (pure mechanical, no logic change), so the diff is
reviewable on its own:

| before | after |
|---|---|
| `IProver` | `IPolicy` |
| `BaseProver` | `BasePolicy` |
| `MessageBridgeProver` / `IMessageBridgeProver` | `MessageBridgePolicy` / `IMessageBridgePolicy` |
| `HyperProver` | `HyperPolicy` |
| `LayerZeroProver` | `LayerZeroPolicy` |
| `MetaProver` | `MetaPolicy` |
| `PolymerProver` | `PolymerPolicy` |
| `CCIPProver` | `CCIPPolicy` |
| `LocalProver` / `ILocalProver` | `LocalPolicy` / `ILocalPolicy` |
| `LocalProverTron` (`contracts/tron/`) | `LocalPolicyTron` |
| `TestProver` / `TestMessageBridgeProver` | `TestPolicy` / `TestMessagePolicy` |
| the `reward.prover` field / vars / NatSpec | `reward.prover` (field name kept to bound churn; the *type* is `IPolicy`) |

The cross-chain fact receipt still authenticates the whitelisted sender (`main`'s `Whitelist`) and the
fact is bound to the `intentHash`.

## 4a. Restored optimizer_runs

Dropping the `nativeAmount` field, the separate `tokens[]` input array, the output balance-delta
measurement loop, and the `route.recipient` field reclaims Portal bytecode (the leftover move to the
intent Vault runs in the separately-deployed `Executor`, which does not count against the Portal). With
the slimmer Portal, `optimizer_runs` is set to **1,000,000** in lockstep across `foundry.toml` and
`hardhat.config.ts` (hardhat previously had no explicit `runs`, i.e. the default 200). At this setting
`Portal` and `PortalTron` are **24,008 bytes** each (**568 bytes** under the 24,576 limit); the runtime
size is flat from 200k–1M runs (via-IR has plateaued), so 1M is chosen for the best runtime-gas
optimization at no size cost. (Net: `recipient` removed and `creator` — the destination vault owner —
added back in its place; headroom is 568 bytes, still comfortably under the limit.)

## 5. What is deferred (NOT in PR2)
- **runtime / delegatecall execution + unified dual-chain vault** → PR3 (Route keeps `salt`, `creator`,
  `calls`, `minTokens`; `route.creator` becomes the executeAsOwner authority there; still the single-sided
  Vault + Executor here).
- **`source` in the intent hash / chain-parameterized vault** → PR3.
- **transport ⊥ policy split** (`PolicyProver` fact store + `RelayBase` transport) → later; PR2 keeps the
  combined prover.
- **policy hooks (`reward.hooks`/`policyData`)** → PR5.
- **streaming / per-slice `seq`** → PR6 (the fulfillment hash intentionally has **no `seq`** here).
- **same-chain first-class + no-upfront-capital flash** → PR4. PR2's `LocalPolicy.flashFulfill` is reworked
  to **fulfill-then-settle** — it provides exactly the `minTokens` input floor (pulling ERC20 legs from the
  caller and forwarding the native leg) and settles with `fulfilled[] == the minTokens amounts`. The reward
  now scales on the provided input, so the v2 withdraw-before-fulfill flash-loan is impossible and is
  deferred.
