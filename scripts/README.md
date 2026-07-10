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
  `POLYMER_CROSS_L2_PROVER_V2`, `CCIP_ROUTER`, and the per-bridge
  `*_CROSS_VM_PROVERS` lists.

- `DeployCCIPProver.s.sol` — Standalone deployment for the CCIP prover.

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

Releases are fully automated. On every push to `main`, the
`.github/workflows/release.yaml` workflow runs semantic-release, which:

1. Determines the next version from conventional commits (`fix:` → patch,
   `feat:` → minor, `BREAKING CHANGE` → major).
2. Rewrites `version()` in all contracts and bumps `package.json`
   (`scripts/release/update-versions.ts`).
3. Updates `CHANGELOG.md`.
4. Commits those changes back to `main` as `chore(release): x.y.z [skip ci]`.
5. Tags `vx.y.z` and publishes a GitHub release.

PR titles must follow conventional-commit format (enforced by
`.github/workflows/pr-title-check.yml`), because squash-merge commits are what
semantic-release analyzes.

Note: the version string is compiled into bytecode, so every release changes
contract bytecode and therefore CREATE2 deterministic deployment addresses.
Contract deployment and npm publishing are deliberately NOT part of the
release flow.

### One-time go-live prerequisites (admin)

The latest released version is `v2.8.17`; tags above it (`v3.x`, `v9.x`,
prerelease tags) were never released and add noise. No stable tag newer than
`v1.6.1` is reachable from `main` (the v2.x line lives on `beta`), so without
a baseline semantic-release would compute the next version from the legacy
v1.x tags. The release workflow refuses to run until this is fixed (the
"Verify release baseline tag" guard requires a reachable stable tag
`>= v2.8.17`). Before the first release from `main`:

1. Prune the never-released tags newer than `v2.8.17` (all `v3.x`, `v9.x`,
   and `-alpha`/`-beta` tags above it), locally and on origin.
2. Create the version baseline on `main`:
   `git tag v2.8.18 <main tip> && git push origin v2.8.18`.
3. When v3 is ready, land a commit with a `BREAKING CHANGE` footer (or
   `feat!:`) — semantic-release cuts `v3.0.0` from it.

### Patching a previous major

Releases bump off `main`, so when a major lands there is no branch to patch
the previous major in production. When `main` bumps to a new major (e.g.
`v2.x → v3.x`), cut a `release-v2.x` branch from the last `v2.x` tag so
production fixes can be cherry-picked and released there while `main` carries
the new line.
