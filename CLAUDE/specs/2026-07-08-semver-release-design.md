# Semver Release Alignment with solver-v2 (PAR-372)

**Date:** 2026-07-08
**Linear:** [PAR-372](https://linear.app/ecoprotocol/issue/PAR-372/copy-semver-files-from-solver-into-eco-routes-repo)
**Status:** Approved

## Problem

eco-routes' release automation has rotted. The existing semantic-release pipeline
runs only on the dormant `beta` branch, couples releasing to on-chain contract
deployment (AWS secrets, deployer private key), and has drifted badly from
reality: `package.json` says `2.1.12`, `.releaserc.json` pins `lastRelease` at
`2.1.5`, `contracts/libs/Semver.sol` hardcodes `"2.6"`, while actual git tags
are at `v3.2.6` (created outside this machinery).

solver-v2 has a clean, working pattern: semantic-release on push to `main`
producing a tag + GitHub release from conventional commits, with PR titles
enforced. We adopt that pattern here, plus one extension: the released version
is written into the contracts' `version()` function.

## Decisions

1. **Replace the old pipeline entirely.** The beta-branch deploy-during-release
   flow is removed from the release path. Contract deployment and npm publishing
   become separate, explicit steps outside the release.
2. **Rewrite `Semver.sol` on release.** A semantic-release prepare step writes
   the version into every `version()` function under `contracts/`, and the
   release commits it back to `main`.
3. **Full `major.minor.patch` granularity** in the contract version string
   (e.g. `"3.2.7"`), accepting that every release changes bytecode and therefore
   CREATE2 deterministic addresses for subsequent deployments.
4. **Full cleanup of the dead deployment pipeline in the same change**:
   legacy workflows, the `scripts/semantic-release/` machinery, its
   only-consumers, and broken `package.json` scripts are all removed.

## Design

### Files added / replaced

| File                                   | Change                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| -------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `.github/workflows/release.yaml`       | Rewritten to solver shape: trigger on push to `main`; one `release` job — checkout (`fetch-depth: 0`), setup Node from `.nvmrc`, `yarn install`, `npx semantic-release`. Exposes `new_release_published` / `new_release_version` job outputs for future downstream jobs. No AWS, no private keys, no deploys, no npm publish.                                                                                                                      |
| `.github/workflows/pr-title-check.yml` | Aligned with solver's `semantic-pr.yml`: `amannn/action-semantic-pull-request` pinned by SHA, explicit `types` list, scoped to PRs targeting `main`.                                                                                                                                                                                                                                                                                               |
| `.releaserc.json`                      | Replaced with minimal config: `branches: ["main"]`; plugins — `commit-analyzer` (angular preset), `release-notes-generator`, `changelog`, `exec` (prepare: version-update script), `git` (assets: `package.json`, `CHANGELOG.md`, rewritten `contracts/**/*.sol`), `github`. The stale pinned `lastRelease` block is dropped; semantic-release resumes from the latest reachable tag (`v3.2.6`). `@semantic-release/npm` is deliberately excluded. |
| `scripts/release/update-versions.ts`   | New small script (~40 lines): given the next version, rewrites every `version()` function under `contracts/` with the full `x.y.z` string and updates `package.json`. Reuses the regex logic from `scripts/semantic-release/solidity-version-updater.ts`, minus the `major.minor` truncation (`getBaseVersion`).                                                                                                                                   |

### Files deleted (dead deployment pipeline)

Dependency mapping confirmed the following chain is referenced by nothing
except itself:

- `.github/workflows/trigger-from-chains.yaml` — pushed empty conventional
  commits to `beta` (from eco-chains dispatches or manual runs) purely to fire
  the old release pipeline. Dead under the new design.
- `scripts/semantic-release/` — the entire directory: the custom plugin
  (`index.js` via `dist/`), `sr-prepare` / `sr-deploy-contracts` /
  `sr-singleton-factory` / `sr-publish` / `sr-verify-conditions` /
  `sr-build-package` / `gen-bytecode` / `verify-contracts` /
  `eco-routes-local`, `solidity-version-updater` (its regex logic moves into
  the new `scripts/release/update-versions.ts`), plus its `tests/` and
  `assets/`.
- `scripts/utils/` — `extract-salt.ts`, `envUtils.ts`, `gitUtils.ts`,
  `processUtils.ts`, `load_env.sh`, `load_chain_data.sh`, and their tests.
  Consumed only by `scripts/semantic-release/` and the shell wrappers below.
- `scripts/deployRoutes.sh`, `scripts/verifyRoutes.sh`,
  `scripts/deploySingletonFactory.sh` — invoked only by
  `sr-deploy-contracts.ts` / `sr-singleton-factory.ts`. The Foundry deploy path
  (`forge script script/Deploy.s.sol`) is unaffected and remains the way to
  deploy.
- `package.json` scripts — remove entries that are part of the dead pipeline
  or point at files that no longer exist: `deployCI`, `deployForgeCI`
  (missing `scripts/deploy/`), `semantic:pub`, `deploy:plugin` (missing
  target), `genBytecode`, `build:semantic-plugin`, `versionPackage`,
  `pub:tag`, `pub:publish` (missing `scripts/publish/`), and `deploy:tron*`
  (missing `scripts/tron-deploy.ts`; TRON deployment is being reworked
  separately under `scripts/tron/`). `pub:clean` / `pub:build` /
  `pub:prepack` stay (used by `clean` and future npm publishing).
- Dev dependencies that only served the deleted code (e.g.
  `@semantic-release/npm`, `semver-utils`) — pruned via `depcheck` during
  implementation; `semantic-release`, `@semantic-release/changelog`,
  `@semantic-release/exec`, `@semantic-release/git`, `@semantic-release/github`
  stay.
- `CLAUDE.md` — update the Commands section (`yarn deployCI`,
  `yarn semantic:pub` no longer exist) to reflect the new release flow.

### Additional repo cleanup (orphaned files)

While mapping the dead pipeline, several unrelated orphans surfaced. They are
removed or relocated in the same change:

- `executeInstructions.ts` (repo root) — 2024 throwaway that generates random
  wallets and prints private keys to the console. Delete.
- `package_working.json` (repo root) — stale `package.json` snapshot from the
  repo's pre-fork `@ecoinc/ecoism` era (2024). Delete.
- `scripts/createXOld/` — self-described "Legacy deployment scripts using
  CreateX (archived)". Delete.
- `deposit_address_userflow.md` and `localprover_flows.md` (repo root) —
  legitimate design docs for shipped features (PRs #367, #354), misplaced at
  root. Move into `CLAUDE/specs/`.
- `scripts/README.md` — currently documents the deleted semantic-release
  deploy system. Rewrite to describe the remaining Foundry deploy scripts and
  the new release flow.
- `README.md` — the deployment section documents `./scripts/deployRoutes.sh`
  (deleted). Update to the Foundry `forge script` path.
- Doc path bug: `CLAUDE.md` and `README.md` document
  `forge script script/Deploy.s.sol`, but no `script/` directory exists — the
  file is `scripts/Deploy.s.sol`. Fix the path in both.

### Files deliberately left alone

- `scripts/Deploy.s.sol` — the main Foundry deploy script; the deploy path
  going forward.
- `scripts/DeployCCIPProver.s.sol` — CCIP prover deployment (current prover
  set).
- `scripts/DeployGatewayERC20Factory.s.sol` and
  `scripts/deployGatewayERC20Factories.sh` — recent feature tooling (PR #381);
  the shell script is self-contained and does not source the deleted
  `scripts/utils/`.
- `scripts/tron/` — in-flight TRON/Polymer work.
- `ci.yaml` — lint + tests only, no deploy references.

### Release flow

1. PR merged to `main`. The PR title check enforces conventional-commit format,
   so squash-merge commits are analyzable.
2. Release workflow runs semantic-release, which finds the last tag (`v3.2.6`)
   and computes the bump from commit types (`fix` → patch, `feat` → minor,
   `BREAKING CHANGE` → major).
3. `exec` prepare step runs `update-versions.ts`: rewrites `version()` in all
   contracts to the new `x.y.z` and bumps `package.json`.
4. `changelog` plugin updates `CHANGELOG.md`.
5. `git` plugin commits all of the above back to `main` as
   `chore(release): x.y.z [skip ci]`.
6. `github` plugin creates tag `vx.y.z` and a GitHub release with generated notes.

Reruns are safe (semantic-release is idempotent per tag). `[skip ci]` prevents
a release loop.

### Edge cases

1. **Branch protection on `main`** — the main operational risk. The `git`
   plugin must push a commit directly to `main`. If branch protection requires
   PRs, the default `GITHUB_TOKEN` push is rejected. Prerequisite before first
   release: add `github-actions[bot]` to the bypass list, or use a GitHub
   App/PAT token in the workflow.
2. **Stray prerelease tags** — `v3.3.0-alpha.1` exists. If reachable from
   `main`, semantic-release could compute a surprising last release. Mitigation:
   run `npx semantic-release --dry-run` before the first real release; fix via
   branch config or tag cleanup if needed.
3. **Test contracts** — `TestProver.sol` and `TestMessageBridgeProver.sol` have
   `version()` functions and are rewritten by the same sweep. Harmless;
   expected in the release diff.

## Testing

- Unit tests (Jest) for `scripts/release/update-versions.ts`: rewrites a
  version function, ignores files without one, writes full `x.y.z`, updates
  `package.json`.
- `forge build` after a simulated rewrite to prove the regex-produced Solidity
  compiles.
- `npx semantic-release --dry-run` gate to confirm the computed next version
  before the workflow runs for real.
- The PR title check validates itself on the PR that introduces it.

## Out of scope

- Contract deployment automation (decoupled; the Foundry
  `forge script script/Deploy.s.sol` path remains).
- npm publishing of `@eco-foundation/routes` (separate, explicit step; the
  broken `pub:tag`/`pub:publish` scripts are removed, so a future publish flow
  must be rebuilt deliberately).
- TRON deployment scripts (`scripts/tron/`, in-flight work).
- Helm publishing (solver-specific; no equivalent here).
