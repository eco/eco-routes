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

Releases flow through a **release PR** — no direct pushes to `main` (the org
ruleset forbids them; see `CLAUDE/specs/2026-07-14-release-pr-bridge-design.md`).

1. On every push to `main`, `.github/workflows/release-pr.yaml` computes the
   next version from conventional commits (semantic-release dry-run), rewrites
   `version()` in the contracts and `package.json`
   (`scripts/release/update-versions.ts`), updates `CHANGELOG.md`, and
   force-pushes an auto-refreshing PR from the fixed branch `autorelease/next`
   titled `chore(release): x.y.z`. While that PR is open, new commits to
   `main` refresh it (version and notes update automatically).
2. A human reviews, approves, and **squash-merges** the release PR. Required
   CI checks run against the rewritten source. The squash commit message must
   stay the PR title (`chore(release): x.y.z`) — the repo merge setting
   should be "Default to pull request title".
3. `.github/workflows/release-tag.yaml` detects the release commit on `main`,
   tags `vx.y.z`, and publishes the GitHub release using the PR body as
   notes. If the squash title was mangled, run this workflow manually via
   workflow_dispatch with the version as input.

The release PR is authored with a GitHub App token (`RELEASE_BOT_APP_ID` /
`RELEASE_BOT_PRIVATE_KEY` repo secrets) so CI triggers on it — the default
`GITHUB_TOKEN` cannot do this. The App needs only Contents + Pull requests
read/write on this repository; it is NOT a ruleset bypass.

The version string is compiled into bytecode, so every release changes
contract bytecode and therefore CREATE2 deterministic deployment addresses.
Contract deployment and npm publishing are deliberately NOT part of the
release flow.

The baseline guard (in `release-pr.yaml`) refuses to compute versions unless
a stable tag `>= v2.8.17` is reachable from `main`.

### Patching a previous major

Releases bump off `main`, so when a major lands there is no branch to patch
the previous major in production. When `main` bumps to a new major (e.g.
`v2.x → v3.x`), cut a `release-v2.x` branch from the last `v2.x` tag so
production fixes can be cherry-picked and released there while `main` carries
the new line.
