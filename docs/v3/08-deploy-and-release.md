# PR8 — deploy script, release pipeline, TS SDK

> Ships the operational layer for v3: a deterministic Foundry deploy script (with the **C1** self-reference
> fix), the npm release-pipeline retarget to the renamed contract set, and a minimal TypeScript SDK. Part
> of the [v3 stack](./00-overview.md); user-facing upgrade story in
> [`migration-from-v2.md`](./migration-from-v2.md).

## 1. `scripts/DeployV3.s.sol` — deterministic deploy

`deploy(Config)` brings up the full v3 set for one chain. It is env-free (a test drives it with a struct);
`run()` / `runTron()` read env, `vm.startBroadcast`, and call it.

### Two address families

| Family | Contracts | Method | Why the address is identical on every chain |
|--------|-----------|--------|---------------------------------------------|
| **CREATE2** (SingletonFactory `0xce00…cf9f`) | `Portal`/`PortalTron`, `MulticallRuntime` | no ctor args ⇒ fixed creation bytecode | CREATE2 = f(factory, salt, bytecode). Same bytecode + salt ⇒ same address (EVM; TVM uses the `0x41` prefix, so its family differs by construction). |
| **CREATE3** (canonical deployer `0xC6BAd1…66814`) | all policies (`Local`, `Hyper`, `Meta`, `LayerZero`, `CCIP`, `Polymer`, `Streaming`, `Vesting`, `Milestone`, `DutchDecay`) | chain-specific ctor args | CREATE3 = f(deployer, salt) **only** — independent of bytecode/ctor-args — so differing bridge endpoints per chain still land on one address. |

Per-contract salt: `keccak256(abi.encode(SALT, keccak256(name)))`; the Portal uses the bare `SALT`. Same
`DEPLOYER_PRIVATE_KEY` + `SALT` must be used on every chain. The script bootstraps the CREATE3 deployer via
the SingletonFactory when absent.

### C1 — the right-aligned self-reference (safety-critical)

Each transport policy (`Hyper`/`Meta`/`LayerZero`/`CCIP`) bakes an IMMUTABLE peer whitelist at
construction that lists its OWN CREATE3 address (its peer on every other chain) plus the configured non-EVM
peers. That self-reference **must** be stored RIGHT-aligned:

```solidity
provers[0] = self.toBytes32();          // bytes32(uint256(uint160(self)))   ✓ correct
// NOT: bytes32(bytes20(self))          // left-aligned                       ✗ C1 bug
```

The transports deliver the cross-chain sender right-aligned (`MessageBridgePolicy._handleCrossChainMessage`
checks `isWhitelisted(messageSender)` against that form). A left-aligned self-reference makes the immutable
`==` never match, so **every EVM↔EVM proof is rejected and solver funds lock**. This encoding mismatch has
appeared before in this codebase's deploy tooling — `DeployV3` uses `AddressConverter.toBytes32` consistently
to avoid it.

`test/v3/deploy/DeployV3.t.sol` asserts, for every transport policy:
`getWhitelist()[0] == self.toBytes32()`, `isWhitelisted(rightAligned) == true`, and — the regression guard
— `isWhitelisted(bytes32(bytes20(self))) == false`. Plus existence, CREATE2/CREATE3 re-derivation,
idempotent re-deploy, and portal wiring. (7 tests, all green.)

Polymer's whitelist is the configured cross-VM peers only (no self-reference) — it authenticates the origin
policy on the source chain via source-emitted events, mirroring the production pattern.

### Env vars

`SALT`, `DEPLOYER_PRIVATE_KEY` (falls back to `PRIVATE_KEY`); per-transport endpoints
(`MAILBOX_CONTRACT`, `ROUTER_CONTRACT`, `LAYERZERO_ENDPOINT` [+ `LAYERZERO_DELEGATE`], `CCIP_ROUTER`,
`POLYMER_CROSS_L2_PROVER_V2` [+ `POLYMER_MAX_LOG_DATA_SIZE`]) — a zero endpoint skips that policy; per-bridge
cross-VM peer lists (`HYPER_CROSS_VM_PROVERS`, `META_CROSS_VM_PROVERS`, `LAYERZERO_CROSS_VM_PROVERS`,
`CCIP_CROSS_VM_PROVERS`, `POLYMER_CROSS_VM_PROVERS`); `MIN_GAS_LIMIT`; `DEPLOY_LOCAL_POLICY` (default true),
`DEPLOY_SCHEDULE_POLICIES` (default false) + `SCHEDULE_RELAYS`; `DEPLOY_FILE` for the address CSV.

### TRON

`runTron()` uses `PortalTron`/`AccountTron`/`LocalPolicyTron` and the `0x41` CREATE2 prefix. As with main,
`forge` cannot broadcast to the TVM — `runTron()` produces the authoritative deploy logic + address
prediction, but a TVM-native harness for the actual broadcast is a remaining follow-up (see loss
inventory).

## 2. Release pipeline

`scripts/semantic-release/sr-build-package.ts` `CONTRACT_TYPES` is retargeted to the full v3 deployed set
(the address-CSV/JSON columns + generated TS types): `Portal`, `MulticallRuntime`, `LocalPolicy`,
`HyperPolicy`, `MetaPolicy`, `LayerZeroPolicy`, `CCIPPolicy`, `PolymerPolicy`, `StreamingPolicy`,
`VestingPolicy`, `MilestonePolicy`, `DutchDecayPolicy`. `gen-bytecode.ts` (CREATE2 bytecode prediction)
covers the two no-ctor-arg contracts (`Portal`, `MulticallRuntime`); the transport policies are CREATE3
(address independent of bytecode) so are not bytecode-derived there. The build-package spec test was
updated to assert the real (not mocked-stale) set.

## 3. TypeScript SDK (`src/`)

A minimal, dependency-light SDK (viem) matching the FINAL structs and hash scheme:

- `src/types.ts` — `Route`/`Reward`/`Intent`/`TokenAmount`/`RewardToken`/`Hook` (+ `WAD`).
- `src/hashing.ts` — `hashRoute`/`hashReward`/`hashIntent`/`hashFulfillment` (source-in-hash; ABI tuple
  strings mirror `contracts/types/Intent.sol`).
- `src/addresses.ts` — `accountSalt(intentHash, roleChainId)` and `predictAccountAddress(...)`. The Account
  is a CREATE2 clone deployed by the Portal; prediction takes the deployment-specific
  `proxyInitCodeHash = keccak256(Proxy.creationCode ++ abi.encode(accountImplementation))` as input.

Parity is proven by a golden vector: `test/v3/sdk/GoldenVector.t.sol` emits the route/reward/intent hashes
of a fixed intent from Solidity; `src/__tests__/hashing.test.ts` builds the same intent in TS and asserts
byte-identical hashes (jest `testMatch` extended to `src/__tests__`).

**Status / scope:** this is a lightweight port — hashing + account-salt + address prediction with a
golden-vector spot-check, not a full parity harness or a published-ABI/addresses bundle. Broader SDK
surface (ABIs, per-chain address exports, ERC-7683 order encoding) is left as follow-up.
