# Eco-Routes Scripts

Operational scripts for the Eco-Routes protocol.

## Directory Structure

- `Deploy.s.sol` — Main Foundry deployment script for the Portal and provers.
  Run from the repo root:

  ```bash
  forge script scripts/Deploy.s.sol --broadcast --rpc-url $RPC_URL
  ```

  Configuration comes from environment variables (see the "Key Environment
  Variables" section of the root `CLAUDE.md` / `README.md`): `SALT`,
  `MAILBOX_CONTRACT`, `ROUTER_CONTRACT`, `LAYERZERO_ENDPOINT`,
  `POLYMER_CROSS_L2_PROVER_V2`, `CCIP_ROUTER`, the per-bridge
  `*_CROSS_VM_PROVERS` lists, and the per-bridge `*_DOMAIN_CONFIG` lists
  (`HYPER_DOMAIN_CONFIG`, `META_DOMAIN_CONFIG`, `LAYERZERO_DOMAIN_CONFIG`).

  Each `*_DOMAIN_CONFIG` value is a comma-separated list of `domain:chainId`
  pairs (e.g. `100:10,200:8453`) that seeds that prover's
  `IMessageBridgeProver.Domain[]` constructor arg; an unset/empty value
  parses to an empty array. `HyperProver`/`MetaProver` fall back to
  `domain == chainId` for any origin not listed, so their config only needs
  to cover exceptions and may be left empty. `LayerZeroProver` uses a strict
  domain->chainId map with no fallback, so `LAYERZERO_DOMAIN_CONFIG` must
  enumerate every origin chain it should accept proofs from.

  Domain-config deploy checklist (security-critical for Hyper/Meta):
  the `domain == chainId` fallback is only safe when every supported source
  chain whose bridge domain differs from its EVM chainId is registered as an
  explicit exception. Before deploying `HyperProver`/`MetaProver`:

  1. List every source chain the prover should accept proofs from.
  2. For each chain where the Hyperlane/Metalayer domain != the chain's
     EVM/protocol chainId, add a `domain:chainId` entry to
     `HYPER_DOMAIN_CONFIG` / `META_DOMAIN_CONFIG`. Omitting such a chain
     leaves a residual: a compromised whitelisted sender on the omitted
     chain can spoof any chain whose real chainId equals the omitted domain
     number. No currently-supported chain is known to need such an entry —
     for the chains in use today (including non-EVM chains like Solana,
     whose Hyperlane domain equals its chainId) the `domain == chainId`
     fallback already resolves the origin correctly, so the config may be
     left empty. Add an exception only for a future chain that genuinely
     has `domain != chainId`.
  3. After deploy, read back the `DomainRegistered(domain, chainId)` events and
     confirm they match the intended map. The constructor already rejects zero
     fields, duplicate domains, and duplicate chainIds, but it cannot detect a
     chain you forgot to list.

  `Deploy.s.sol` also deploys `AggregatorProver`, a stateless 1-of-N union over other
  provers on the same chain, when `AGGREGATOR_PROVER_MEMBERS` is set: an ordered,
  comma-separated list of member prover addresses (max 8) — **order is
  priority**, the first member with a non-zero claimant wins. Each element may
  be a 20-byte address or a full 32-byte `bytes32` (left-padded
  automatically), e.g.:

  ```bash
  AGGREGATOR_PROVER_MEMBERS=0x1111111111111111111111111111111111111111,0x2222222222222222222222222222222222222222
  ```

  Unset or empty skips aggregator deployment; any other malformed value (wrong
  element length, a trailing comma, etc.) now fails the deploy loudly rather
  than silently skipping it. `AGGREGATOR_PROVER_ALLOW_UNVERIFIED_MEMBERS=true` is an
  **unsafe escape hatch** that admits members not deployed in this run —
  domain-lane verification is skipped entirely for members admitted this way,
  so leave it unset unless you have separately, out-of-band verified the
  member's domain table against the bridge operator's published values.

  Three things about the member set are worth knowing before you run this:

  1. **The member set is part of the aggregator's CREATE3 salt.** Changing the
     list, or just reordering it, re-derives a new aggregator address by itself
     — you do **not** change `SALT`, which is the root salt for the whole stack
     and would move every other prover's address too. The flip side is that the
     aggregator only shares one address across chains where the member set is
     identical.
  2. **A `HyperProver`/`MetaProver` member requires a non-empty
     `HYPER_DOMAIN_CONFIG`/`META_DOMAIN_CONFIG`.** Those resolvers fall back to
     `chainId != 0 ? chainId : originDomain`, so an omitted lane records a
     wrong-but-plausible destination instead of failing closed — which shadows
     a valid proof held by a lower-priority member, and the refund path cannot
     recover from that. This requirement applies **only** when the prover is an
     aggregator member; for an ordinary deploy those configs stay
     exceptions-only. `LayerZeroProver` is exempt (strict map, no fallback).
  3. **Every member must already have code on the chain you are deploying to.**
     The constructor reverts `MemberHasNoCode` rather than skipping a codeless
     member at runtime, so onboarding a chain before all members are live fails
     loudly instead of quietly deploying a smaller trust set.

- `DeployCCIPProver.s.sol` — Standalone deployment for the CCIP prover.
  Also reads `CCIP_DOMAIN_CONFIG` (same `domain:chainId` comma-separated
  format). `CCIPProver` uses a strict domain->chainId map like LayerZero, so
  this config must enumerate every origin chain it should accept proofs
  from; an unset/empty value parses to an empty array but will cause the
  deployed prover to reject all incoming proofs until configured.

- `DeployGatewayERC20Factory.s.sol` + `deployGatewayERC20Factories.sh` —
  Deploys the GatewayERC20 factory across chains (see PR #381). The shell
  script wraps the Foundry script per chain:

  ```bash
  PRIVATE_KEY=... SALT=... ./scripts/deployGatewayERC20Factories.sh
  ```

- `release/` — Release automation. `update-versions.ts` is invoked by
  semantic-release (via `@semantic-release/exec` in `.releaserc.json`) to write
  the released version into every contract `version()` function and
  `package.json`. Not meant to be run manually, but can be:

  ```bash
  npx tsx scripts/release/update-versions.ts 3.2.7
  ```

- `tron/` — TRON deployment and E2E scripts (in active development).

## Releases

The release process (auto-refreshing release PR → approve → squash-merge →
tag + GitHub release) is documented in [`RELEASE.md`](../RELEASE.md) at the
repo root. The `scripts/release/update-versions.ts` step above is the piece
that lives here.
