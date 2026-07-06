# PR12 — standing deposit-address streaming (deposit template migration)

**Branch:** `v3/12-deposit-streaming` (base `v3/11-same-chain-flash`)

## Goal

Migrate the reusable deposit-address templates from **"every deposit publishes + funds a FRESH one-shot
intent"** to **"ONE STANDING intent per deposit address, drawn down per deposit"**, riding the
`StreamingFlashPolicy` / `StreamingPolicy` machinery shipped in PR11 — with **ZERO diffs to the core**
(Portal / IntentSource / Inbox / Account / all existing policies / `BaseDepositAddress` /
`BaseDepositFactory` / the three OLD one-shot templates + factories are all untouched). The only new
bytecode lives under `contracts/deposit/` and `contracts/runtime/`.

Deposit clones are immutable CREATE2 contracts, so a migration is **new templates/factories**, never an
in-place upgrade. The three OLD one-shot templates/factories are LEFT IN PLACE (deletion is deferred to a
human deploy-confirmation — nothing on-chain changes when they are eventually removed).

## What ships

New, additive only:

- `contracts/runtime/CCTPBurnRuntime.sol` — stateless balance-reading delegatecall runtime: burns the
  Account's whole balance of the configured token via CCTP `depositForBurn`, minting to a fixed
  `mintRecipient`. Payload commits **CONFIG ONLY** (`token, messenger, destinationDomain, mintRecipient,
  maxFeeBps`); the amount `x` and `maxFee = ceil(x * maxFeeBps / 100000)` are derived LIVE.
- `contracts/runtime/GatewayDepositRuntime.sol` — stateless balance-reading runtime: deposits the
  Account's whole balance of the configured token into the Gateway for the user. Payload: `token, gateway,
  recipient`.
- `contracts/deposit/StandingDepositAddress.sol` — thin base: init, direct-transfer top-up
  (`sweep`/`fundPool`/`fundPoolWithApproval`), `poolAccount()`, the salt-epoch scheme, keeper `reopen`.
- `contracts/deposit/StandingDepositAddress_CCTPMint.sol` — the ONE parameterized CCTP + Gateway template,
  shared by both families; `contracts/deposit/StandingDepositFactory_CCTPMint{,_Arc,_GatewayERC20}.sol`.
- `contracts/deposit/StandingDepositAddress_USDCTransfer_Solana.sol` + its standalone factory.

## CCTP families → two standing `StreamingFlashPolicy` pools

Both the Arc and GatewayERC20 families become **two standing flash pools** per deposit address:

- **Intent 1 (CCTP burn)** — a same-chain pool on the SOURCE chain (`source == destination ==
  block.chainid`), runtime `CCTPBurnRuntime`, reward leg `{sourceUSDC, rate: RATE_1, flat: 0}`. Rate-only
  leg ⇒ `publishAndFund` marks it `Funded` with **zero token pull**. Deposits are swept into its escrow
  Account; solvers draw it down with `flashSlice(pv, route1, reward1, claimant, "")` in **DIRECT mode**
  (reward token == input token == USDC ⇒ **zero solver capital**). The slice is burned via CCTP to
  `account2`; the margin `pool - slice` is the fee.
- **Intent 2 (Gateway deposit)** — a same-chain pool on the DESTINATION chain (`source == destination ==
  DESTINATION_CHAIN_ID`), runtime `GatewayDepositRuntime`, reward leg `{destUSDC, rate: WAD, flat: 0}`.
  Driven by `flashSlice` on the destination chain; the user receives the full CCTP net (margin 0 at
  `rate == WAD`).

### The source-chain-id FIX

The one-shot templates committed intent 2 with `source = block.chainid` while its escrow (the CCTP mint)
lands on the destination chain. Every source-side settle op is `onlySourceChain(source)` and
`flashSlice` hard-commits `block.chainid` on BOTH hash sides, so settlement could only ever run where
`source == destination == block.chainid` — masked in tests by forcing the two chain ids equal. PR12
commits `source = DESTINATION_CHAIN_ID`, so `flashSlice` / `settleStream` / `closeStream` run on the
chain the mint actually lands on. `publish()` is ungated, so the source clone legally publishes intent 2
(source = Arc) for discovery + to pin `account2`; `publishAndFund` (gated) is used ONLY for intent 1.

`account2` is STABLE (its hash has no timestamp; the Account CREATE2 salt is uniform cross-chain), so
intent 1 can bake a fixed `mintRecipient = bytes32(account2)` with **no circularity**.

### Arc: 6-dec `arcUsdc` ERC20, no scaling

Arc's CCTP TokenMessenger mints the **6-decimal `arcUsdc` ERC20** (not native), so intent 2's pool/input
legs are that ERC20 and the `1e12 NATIVE_USDC_SCALING` is **deleted**. This makes Arc structurally
identical to the GatewayERC20 family — hence the single shared template.

### Fee = reward-leg rate spread ONLY (never a payload fee)

- Arc: `RATE_1 = RATE_2 = WAD` (zero protocol spread; the operator runs the draw-down as a gas-paid
  service, user receives the full net).
- GatewayERC20: `RATE_1 = WAD * 100000 / (100000 - protocolFeeBps)` (≥ WAD) — the old fixed absolute
  `FLAT_FEE` becomes a PROPORTIONAL per-slice spread (`margin ≈ pool * protocolFeeBps / 100000`).
  `protocolFeeBps == 0` reproduces the pre-feature zero-fee behavior (`RATE_1 == WAD`). The old
  `AmountBelowFlatFee` guard is replaced by the pool's `MIN_SLICE_1` dust floor (`SliceBelowFloor`).

`draw-down = operator-run`: the default rate is `WAD` (zero user spread), a per-factory config knob.
Constructor sanity checks reject the config footguns that BRICK a published pool: `RATE_* < WAD` (slice >
pool, underfunded advance) and `maxFeeBps >= 100000` (CCTP maxFee ≥ slice, burn rejected).

## Solana family → one cross-chain standing `StreamingPolicy` intent

`StandingDepositAddress_USDCTransfer_Solana` publishes ONE cross-chain standing streaming intent: source =
this EVM chain (holds the USDC pool), destination = Solana (`1399811149`), a single pure-rate reward leg
on the source USDC (`rate = REWARD_RATE >= WAD`, `flat == 0` — a streaming `flat` is charged once per
intent lifetime, wrong for a reusable address, so the rate spread is the only fee channel). Flash does NOT
apply: escrow (EVM) and execution (Solana) are on different chains with two distinct Model-C accounts, so
a solver genuinely fronts USDC on Solana and is repaid from the EVM pool after the batch is bridged back
(a whitelisted relay `recordBatch` → permissionless `settleStream` paying `fulfilled * rate / WAD`).

**Placeholder route (documented residual):** the EVM half is fully functional and testable now (publish /
pool / relay-record / settle / close / epoch). The route bytes are a DETERMINISTIC PLACEHOLDER Borsh
encoding (amount == 0, deadline == max) — the one-shot template's per-deposit u64 `AmountTooLarge` guard
is deleted (there is no per-deposit amount under streaming; the u64 SPL constraint is enforced per slice
on the SVM side). **The real re-fulfillable SVM streaming program (variable per-slice amount + actual SPL
`transfer_checked` delivery) is a required out-of-repo follow-up; the EVM placeholder route is NOT
executable as-is.**

## Salt-epoch lifecycle

The route salt is `keccak256(abi.encode(address(this), epoch))` — deterministic (no `block.timestamp`),
so the standing hash and pool address are STABLE and collision-free (no same-block warp dance). Deadlines
are `type(uint64).max` so the permissionless post-deadline `refund` can never terminate a pool; the keeper
exit is `closeStream` per pool. Because `closeStream` is terminal (`Refunded`) and a `Refunded` hash can
never be re-published, a keeper `reopen` (bump `epoch`, re-open under fresh hashes) is the only restart
path. `reopen` is keeper-only and gated on the current epoch's **source-chain** intents being `Refunded`.

## Deploy + packaging

`scripts/DeployV3.s.sol` (additive): the flash block also deploys the `GatewayDepositRuntime` via CREATE3
(uniform cross-chain address, committed into intent-2's route hash → `account2`); `StreamingFlashPolicy`
(both chains, one CREATE3 address) and the Solana `StreamingPolicy(portal, relays)` are already deployed;
a new env-gated (`DEPLOY_DEPOSIT_FACTORIES`, off by default) block deploys the three standing factories
(the CCTP factory self-deploys its own source-side `CCTPBurnRuntime`). `sr-build-package.ts`
`CONTRACT_TYPES` gains the two runtimes and three factories (length 16 → 21).

## Documented residual risks / boundaries

- **Placeholder Solana route** — not executable until the out-of-repo SVM streaming program lands.
- **Solana relay is fully trusted for pool integrity** — a malicious relay + colluding settler can
  fabricate a `batchHash` + matching preimage to mint payouts for slices never delivered on Solana. A
  bridge-backed `StreamingPolicy` subclass (real mailbox proof) is the mandatory production hardening.
- **Solana cross-chain close window** — `hasUnsettledFulfillment` reads only the local EVM policy, so a
  slice delivered on Solana but not yet proven+relayed is invisible; a keeper `closeStream` in that
  latency window strands the solver's delivery. Off-chain mitigation (solver checks source status before
  delivering; keeper honesty). Inherent to cross-chain streaming; the flash CCTP legs are atomic and
  immune.
- **Epoch rotation vs in-flight CCTP** — a burn under epoch N names `account2(N)` as `mintRecipient`; if
  the keeper `closeStream`+`reopen`s to N+1 while that CCTP message is in flight, the late mint lands at
  `account2(N)` on the destination chain. Note `reopen` closes only intent 1 (the source pool — see the
  cross-chain-keeper item below), so `account2(N)` (intent 2) is **not** closed and the late mint is fully
  recoverable: the primary path is a normal `flashSlice(intent2 N)` on the destination chain, which
  delivers the mint to the intended end-user; the fallback is a keeper `closeStream(intent2 N)`, which
  refunds it to `reward.keeper` (the depositor). Note `recoverToken` does **not** apply here — the minted
  token is intent 2's reward-leg token, which `_validateRecover` rejects (`InvalidRecoverToken`).
  Operationally, **rotate epochs only after in-flight CCTP has drained.**
- **Deposit sweep during the `close`→`reopen` window** — `sweep`/`fundPool` are permissionless and route
  the clone's balance into the *current-epoch* pool Account. Between a keeper's `closeStream(intent1 N)`
  and `reopen` (which bumps the epoch), the current-epoch account is the now-closed `account1(N)`, so a
  straggler sweep parks funds there and `flashSlice`/`settleStream` on it revert (closed/terminal). No
  funds are lost or misdirected: `closeStream` has no status gate and `hasUnsettledFulfillment` is always
  false for a flash pool, so the keeper re-invokes `closeStream(intent1 N)` to refund the swept balance to
  the depositor, and `reopen` still proceeds (its gate only requires intent 1 `Refunded`). Mitigation:
  pause deposits during rotation, or batch `closeStream`+`reopen` atomically from a contract keeper.
- **Cross-chain keeper UX for CCTP intent 2** — its `closeStream`, status, and dust-reclaim are all
  destination-chain (Arc) keeper actions, so `reopen`'s gate only checks intent 1 (the source pool);
  intent 2's destination-side `Refunded` status is not readable on the source chain. A depositor who
  cannot operate on Arc cannot reclaim intent-2 dust (consider a protocol keeper for intent 2).
- **Zero-margin legs need an operator** — at `rate == WAD` a permissionless solver has no incentive to run
  the slice; the protocol operator runs those `flashSlice` calls (economic, not a safety hole).
