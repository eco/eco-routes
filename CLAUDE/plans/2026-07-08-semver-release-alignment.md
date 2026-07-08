# Semver Release Alignment (PAR-372) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace eco-routes' dead beta-branch deploy-coupled release pipeline with a solver-v2-style semantic-release flow on `main` that also writes the released version into the contracts' `version()` functions, and delete the dead deployment machinery plus orphaned files.

**Architecture:** semantic-release runs on push to `main` (GitHub Actions), computes the next version from conventional commits, rewrites `version()` in all Solidity contracts via a small `@semantic-release/exec` prepare script, commits `package.json` + `CHANGELOG.md` + rewritten contracts back as `chore(release): x.y.z [skip ci]`, then tags and publishes a GitHub release. Everything the old pipeline needed (deploy scripts, AWS, npm publish) is deleted.

**Tech Stack:** semantic-release 23 (+ changelog/exec/git/github plugins, already in devDependencies), tsx, Jest (ts-jest), GitHub Actions, Foundry (verification only).

**Spec:** `CLAUDE/specs/2026-07-08-semver-release-design.md` (approved).

## Global Constraints

- Commit messages: conventional format (`<type>: <description>`), NO co-author lines, NO Claude attribution.
- Only commit files you changed in the task at hand.
- Do NOT push to any remote in this plan. Pushing/PR creation happens after the whole plan is done and reviewed (this is CI/release tooling, not a contract security fix, so the normal PR flow applies — but it's a separate, explicit step).
- Contract version granularity: full `major.minor.patch` (e.g. `"3.2.7"`).
- The new release flow must NOT deploy contracts and must NOT publish to npm.
- Node version: v22.10.0 (from `.nvmrc`). Package manager: yarn 1 (yarn.lock).
- The version-rewrite regex (must stay byte-identical to what's in the codebase today, it is battle-tested): `/function version\(\) external pure returns \(string memory\) \{[^}]*\}/`

---

### Task 0: Create the working branch

**Files:** none (git only)

- [ ] **Step 1: Create the branch (Linear's suggested name) from current HEAD**

The approved spec commit (`docs: add semver release alignment design spec (PAR-372)`) sits on local `main` and must ride along on the branch.

```bash
git checkout -b cfebres/par-372-copy-semver-files-from-solver-into-eco-routes-repo
```

Note: local `main` is left pointing at the spec commit; after the branch is pushed/merged the user can `git branch -f main origin/main`. Do not do that in this plan.

- [ ] **Step 2: Verify clean state**

Run: `git status --short`
Expected: only the pre-existing untracked `scripts/tron/*` files (TRON-POLYMER-E2E.md, deploy-evm-tron-polymer.ts, publish-*.ts, relay-*.ts). Leave them alone throughout this plan.

---

### Task 1: Version-update script (TDD)

**Files:**
- Create: `scripts/release/update-versions.ts`
- Create: `scripts/release/tests/update-versions.spec.ts`
- Modify: `jest.config.js` (testMatch currently points ONLY at `scripts/semantic-release/tests/**`, which Task 3 deletes)

**Interfaces:**
- Produces: `updateSolidityVersions(rootDir: string, version: string): string[]` (returns updated file paths), `updatePackageJsonVersion(rootDir: string, version: string): void`, and a CLI entry: `npx tsx scripts/release/update-versions.ts <x.y.z>` run from repo root. Task 2's `.releaserc.json` prepareCmd calls this CLI.

- [ ] **Step 1: Update jest.config.js so the new test location is discovered**

Replace the `testMatch` line in `jest.config.js`:

```js
/** @type {import('ts-jest').JestConfigWithTsJest} **/
module.exports = {
  testEnvironment: 'node',
  testPathIgnorePatterns: ['/node_modules/'],
  testMatch: ['**/scripts/release/tests/**/*.spec.ts'],
  transform: {
    '^.+\\.tsx?$': ['ts-jest', {}],
  },
  passWithNoTests: true,
}
```

(The old `scripts/semantic-release/tests` are NOT in testMatch anymore from this point; that's intentional — that whole directory is deleted in Task 3.)

- [ ] **Step 2: Write the failing test**

Create `scripts/release/tests/update-versions.spec.ts`:

```ts
import * as fs from 'fs'
import * as os from 'os'
import * as path from 'path'
import {
  updateSolidityVersions,
  updatePackageJsonVersion,
} from '../update-versions'

const VERSIONED_CONTRACT = `// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

abstract contract Semver {
    /**
     * @notice Returns the semantic version of the contract
     */
    function version() external pure returns (string memory) {
        return "2.6";
    }
}
`

const UNVERSIONED_CONTRACT = `// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

contract Plain {
    function foo() external pure returns (uint256) {
        return 1;
    }
}
`

describe('update-versions', () => {
  let rootDir: string

  beforeEach(() => {
    rootDir = fs.mkdtempSync(path.join(os.tmpdir(), 'update-versions-'))
    fs.mkdirSync(path.join(rootDir, 'contracts', 'libs'), { recursive: true })
    fs.writeFileSync(
      path.join(rootDir, 'contracts', 'libs', 'Semver.sol'),
      VERSIONED_CONTRACT,
    )
    fs.writeFileSync(
      path.join(rootDir, 'contracts', 'Plain.sol'),
      UNVERSIONED_CONTRACT,
    )
    fs.writeFileSync(
      path.join(rootDir, 'package.json'),
      JSON.stringify({ name: 'x', version: '0.0.0' }, null, 2) + '\n',
    )
  })

  afterEach(() => {
    fs.rmSync(rootDir, { recursive: true, force: true })
  })

  it('rewrites version() with the full x.y.z string, recursively', () => {
    const updated = updateSolidityVersions(rootDir, '3.2.7')

    expect(updated).toHaveLength(1)
    const content = fs.readFileSync(
      path.join(rootDir, 'contracts', 'libs', 'Semver.sol'),
      'utf8',
    )
    expect(content).toContain('return "3.2.7";')
    expect(content).not.toContain('return "2.6";')
  })

  it('produces compilable-shaped output (single well-formed function)', () => {
    updateSolidityVersions(rootDir, '3.2.7')
    const content = fs.readFileSync(
      path.join(rootDir, 'contracts', 'libs', 'Semver.sol'),
      'utf8',
    )
    expect(content).toContain(
      'function version() external pure returns (string memory) { return "3.2.7"; }',
    )
  })

  it('leaves files without a version() function untouched', () => {
    updateSolidityVersions(rootDir, '3.2.7')
    const content = fs.readFileSync(
      path.join(rootDir, 'contracts', 'Plain.sol'),
      'utf8',
    )
    expect(content).toBe(UNVERSIONED_CONTRACT)
  })

  it('is idempotent (second run reports zero updates)', () => {
    updateSolidityVersions(rootDir, '3.2.7')
    const second = updateSolidityVersions(rootDir, '3.2.7')
    expect(second).toHaveLength(0)
  })

  it('updates package.json version without touching other fields', () => {
    updatePackageJsonVersion(rootDir, '3.2.7')
    const pkg = JSON.parse(
      fs.readFileSync(path.join(rootDir, 'package.json'), 'utf8'),
    )
    expect(pkg).toEqual({ name: 'x', version: '3.2.7' })
  })
})
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `yarn test:ts`
Expected: FAIL — `Cannot find module '../update-versions'`.

- [ ] **Step 4: Write the implementation**

Create `scripts/release/update-versions.ts`:

```ts
/**
 * semantic-release prepare hook (called via @semantic-release/exec):
 * writes the released version into every ISemver `version()` function under
 * contracts/ and into package.json.
 *
 * Usage: npx tsx scripts/release/update-versions.ts <x.y.z>
 *
 * The version string is compiled into bytecode; changing it changes CREATE2
 * deployment addresses. Full major.minor.patch is intentional (see
 * CLAUDE/specs/2026-07-08-semver-release-design.md).
 */
import * as fs from 'fs'
import * as path from 'path'

const VERSION_FUNCTION_REGEX =
  /function version\(\) external pure returns \(string memory\) \{[^}]*\}/

const SEMVER_REGEX = /^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$/

export function updateSolidityVersions(
  rootDir: string,
  version: string,
): string[] {
  const updated: string[] = []

  function walk(dir: string): void {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const fullPath = path.join(dir, entry.name)
      if (entry.isDirectory()) {
        walk(fullPath)
      } else if (entry.name.endsWith('.sol')) {
        const content = fs.readFileSync(fullPath, 'utf8')
        if (!VERSION_FUNCTION_REGEX.test(content)) {
          continue
        }
        const next = content.replace(
          VERSION_FUNCTION_REGEX,
          `function version() external pure returns (string memory) { return "${version}"; }`,
        )
        if (next !== content) {
          fs.writeFileSync(fullPath, next, 'utf8')
          updated.push(fullPath)
        }
      }
    }
  }

  walk(path.join(rootDir, 'contracts'))
  return updated
}

export function updatePackageJsonVersion(
  rootDir: string,
  version: string,
): void {
  const pkgPath = path.join(rootDir, 'package.json')
  const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf8'))
  const next = { ...pkg, version }
  fs.writeFileSync(pkgPath, JSON.stringify(next, null, 2) + '\n', 'utf8')
}

export function main(argv: string[]): void {
  const version = argv[2]
  if (!version || !SEMVER_REGEX.test(version)) {
    console.error(
      `Usage: npx tsx scripts/release/update-versions.ts <x.y.z> (got: ${version ?? 'nothing'})`,
    )
    process.exit(1)
  }
  const rootDir = process.cwd()
  const updated = updateSolidityVersions(rootDir, version)
  updatePackageJsonVersion(rootDir, version)
  console.log(
    `Updated ${updated.length} Solidity file(s) and package.json to ${version}`,
  )
  for (const file of updated) {
    console.log(`  - ${path.relative(rootDir, file)}`)
  }
}

if (require.main === module) {
  main(process.argv)
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `yarn test:ts`
Expected: PASS — 5 tests in `scripts/release/tests/update-versions.spec.ts`.

- [ ] **Step 6: Smoke-test the CLI against the real repo, then revert**

```bash
npx tsx scripts/release/update-versions.ts 9.9.9
grep -rn '9.9.9' contracts/libs/Semver.sol contracts/test/TestProver.sol
forge build
git checkout -- contracts package.json
```

Expected: grep shows `return "9.9.9";` in both files; `forge build` succeeds (proves the regex output compiles); checkout reverts.
Also verify bad input: `npx tsx scripts/release/update-versions.ts not-a-version` → exits 1 with usage message.

- [ ] **Step 7: Commit**

```bash
git add scripts/release/ jest.config.js
git commit -m "feat: add release version-update script for contracts and package.json"
```

---

### Task 2: Release configuration and workflows

**Files:**
- Modify (full replace): `.releaserc.json`
- Modify (full replace): `.github/workflows/release.yaml`
- Modify (full replace): `.github/workflows/pr-title-check.yml`
- Delete: `.github/workflows/trigger-from-chains.yaml`

**Interfaces:**
- Consumes: the CLI from Task 1 (`npx tsx scripts/release/update-versions.ts ${nextRelease.version}`).
- Produces: job outputs `new_release_published`, `new_release_version`, `new_release_git_tag` on the `release` job (for future downstream jobs).

- [ ] **Step 1: Replace `.releaserc.json` with the minimal config**

Full new content (replaces the beta-branch/custom-plugin/pinned-lastRelease config entirely):

```json
{
  "branches": ["main"],
  "plugins": [
    [
      "@semantic-release/commit-analyzer",
      {
        "preset": "angular",
        "parserOpts": {
          "noteKeywords": ["BREAKING CHANGE", "BREAKING CHANGES"]
        }
      }
    ],
    "@semantic-release/release-notes-generator",
    "@semantic-release/changelog",
    [
      "@semantic-release/exec",
      {
        "prepareCmd": "npx tsx scripts/release/update-versions.ts ${nextRelease.version} && npx prettier --write 'contracts/**/*.sol'",
        "successCmd": "if [ -n \"$GITHUB_OUTPUT\" ]; then echo \"new_release_published=true\" >> \"$GITHUB_OUTPUT\"; echo \"new_release_version=${nextRelease.version}\" >> \"$GITHUB_OUTPUT\"; echo \"new_release_git_tag=${nextRelease.gitTag}\" >> \"$GITHUB_OUTPUT\"; fi"
      }
    ],
    [
      "@semantic-release/git",
      {
        "assets": ["package.json", "CHANGELOG.md", "contracts/**/*.sol"],
        "message": "chore(release): ${nextRelease.version} [skip ci]\n\n${nextRelease.notes}"
      }
    ],
    "@semantic-release/github"
  ]
}
```

Notes for the implementer: `@semantic-release/npm` is deliberately absent (no npm publish; package.json is bumped by our exec script). The prettier pass keeps the single-line rewritten `version()` functions formatted like the rest of the repo (prettier-plugin-solidity is configured). The old `repositoryUrl` and `lastRelease` keys are dropped — semantic-release derives both from git.

- [ ] **Step 2: Replace `.github/workflows/release.yaml`**

Full new content (solver-v2 shape; runs semantic-release directly because our config needs repo-local devDependencies):

```yaml
name: Release

on:
  push:
    branches: [main]

permissions:
  contents: write
  issues: write
  pull-requests: write

jobs:
  release:
    name: Create and Publish Release
    runs-on: ubuntu-latest
    outputs:
      new_release_published: ${{ steps.semantic.outputs.new_release_published }}
      new_release_version: ${{ steps.semantic.outputs.new_release_version }}
      new_release_git_tag: ${{ steps.semantic.outputs.new_release_git_tag }}
    steps:
      - uses: actions/checkout@v4.2.2
        with:
          fetch-depth: 0 # semantic-release needs full history + tags

      - uses: actions/setup-node@v4.1.0
        with:
          node-version-file: ".nvmrc"
          cache: "yarn"

      - name: Install dependencies
        run: yarn install --frozen-lockfile

      - name: Run semantic-release
        id: semantic
        run: npx semantic-release
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

- [ ] **Step 3: Replace `.github/workflows/pr-title-check.yml`**

Full new content (solver-v2's semantic-pr.yml, SHA-pinned, scoped to main):

```yaml
name: Semantic PR

on:
  pull_request:
    types: [opened, edited, synchronize, reopened]
    branches: [main]

permissions:
  pull-requests: read

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: amannn/action-semantic-pull-request@e32d7e603df1aa1ba07e981f2a23455dee596825 # v5
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        with:
          types: |
            feat
            fix
            docs
            style
            refactor
            perf
            test
            build
            ci
            chore
            revert
          requireScope: false
```

- [ ] **Step 4: Delete the legacy trigger workflow**

```bash
git rm .github/workflows/trigger-from-chains.yaml
```

- [ ] **Step 5: Dry-run semantic-release to verify version computation**

```bash
GITHUB_TOKEN=$(gh auth token) npx semantic-release --dry-run --no-ci \
  --branches "$(git rev-parse --abbrev-ref HEAD)"
```

Expected in output:
- `Found git tag v3.2.6 associated with version 3.2.6` (or similar — the last release MUST be 3.2.x, NOT 2.1.5 and NOT 3.3.0-alpha.1; if it picks the alpha tag, stop and flag it for a human decision per the spec's edge case 2)
- `The next release version is 3.X.Y` (patch/minor above 3.2.6, depending on commits since the tag)
- The exec prepare step listing updated Solidity files
- NO actual tag/release created (dry run), NO npm steps mentioned.

Afterwards run `git status --short` — dry-run must not leave modified files (prepare steps are skipped in dry-run; if `contracts/` or `package.json` show modified, `git checkout -- contracts package.json CHANGELOG.md`).

- [ ] **Step 6: Commit**

```bash
git add .releaserc.json .github/workflows/release.yaml .github/workflows/pr-title-check.yml
git rm --cached --ignore-unmatch .github/workflows/trigger-from-chains.yaml >/dev/null 2>&1 || true
git commit -m "feat: adopt solver-style semantic-release on main with contract version rewriting"
```

(If the `git rm` in Step 4 already staged the deletion, the second line is a no-op.)

---

### Task 3: Delete the dead deployment pipeline and prune package.json

**Files:**
- Delete: `scripts/semantic-release/` (entire directory), `scripts/utils/` (entire directory), `scripts/createXOld/` (entire directory), `scripts/deployRoutes.sh`, `scripts/verifyRoutes.sh`, `scripts/deploySingletonFactory.sh`, `executeInstructions.ts`, `package_working.json`
- Modify: `package.json` (scripts + devDependencies + version), `yarn.lock` (regenerated)

**Interfaces:**
- Consumes: nothing from other tasks (pure deletion). Task 1 must already be committed (the new script must not live inside a deleted directory — it lives in `scripts/release/`, which is kept).

- [ ] **Step 1: Delete the dead files**

```bash
git rm -r scripts/semantic-release scripts/utils scripts/createXOld
git rm scripts/deployRoutes.sh scripts/verifyRoutes.sh scripts/deploySingletonFactory.sh
git rm executeInstructions.ts package_working.json
```

- [ ] **Step 2: Prune package.json scripts**

Remove exactly these entries from `"scripts"` (all reference deleted or long-missing files):
`versionPackage`, `deployCI`, `deployForgeCI`, `semantic:pub`, `pub:tag`, `pub:publish`, `deploy:plugin`, `genBytecode`, `build:semantic-plugin`, `deploy:tron`, `deploy:tron:nile`, `deploy:tron:shasta`, `deploy:tron:mainnet`.

Keep: `release` (`semantic-release` — used by the workflow via npx, harmless and documents intent), `pub:clean`, `pub:build`, `pub:prepack` (used by `clean` and future npm publishing), and everything else.

- [ ] **Step 3: Prune devDependencies and align version**

In `package.json`:
- Remove devDependencies: `@semantic-release/npm`, `semver`, `semver-utils`, `@types/semver-utils` (verified used only by the deleted code).
- Set `"version": "3.2.6"` (matches the latest real tag; semantic-release derives versions from tags, this is purely to stop the 2.1.12 lie).

Then regenerate the lockfile:

```bash
yarn install
```

Expected: completes without errors; `yarn.lock` shrinks.

- [ ] **Step 4: Sweep for dangling references**

```bash
grep -rn "semantic-release/\|scripts/utils\|deployRoutes\|verifyRoutes\|deploySingletonFactory\|createXOld\|executeInstructions\|package_working\|deployCI\|semver-utils" \
  --include="*.ts" --include="*.js" --include="*.json" --include="*.yaml" --include="*.yml" --include="*.sh" \
  . 2>/dev/null | grep -v node_modules | grep -v yarn.lock | grep -v CLAUDE/ | grep -v CHANGELOG.md
```

Expected: matches ONLY in `README.md`, `scripts/README.md`, and `CLAUDE.md` (fixed in Task 4), plus `.releaserc.json`'s `scripts/release/update-versions.ts` line (that's the NEW script — fine). Anything else: investigate and fix before continuing.

Also run the optional unused-dependency report (informational — do not remove anything beyond Step 3's list without human sign-off):

```bash
yarn depcheck
```

- [ ] **Step 5: Verify build and tests still work**

```bash
yarn build
yarn test:ts
forge test --no-match-path "test/tron/*" -q
```

Expected: hardhat compile succeeds, jest runs the 5 Task-1 tests (and nothing from the deleted dirs), forge tests pass.

- [ ] **Step 6: Commit**

```bash
git add package.json yarn.lock
git commit -m "chore: remove dead deploy-during-release pipeline and orphaned files"
```

(The `git rm` deletions from Step 1 are already staged.)

---

### Task 4: Documentation updates and doc relocations

**Files:**
- Move: `deposit_address_userflow.md` → `CLAUDE/specs/deposit_address_userflow.md`, `localprover_flows.md` → `CLAUDE/specs/localprover_flows.md`
- Modify (full replace): `scripts/README.md`
- Modify: `README.md` (deployment section, lines ~383–421, plus `script/Deploy.s.sol` path fixes at lines 237, 391, 398, 405)
- Modify: `CLAUDE.md` (Development commands section)

- [ ] **Step 1: Relocate the misplaced design docs**

```bash
git mv deposit_address_userflow.md CLAUDE/specs/deposit_address_userflow.md
git mv localprover_flows.md CLAUDE/specs/localprover_flows.md
```

- [ ] **Step 2: Replace `scripts/README.md`**

Full new content:

```markdown
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
```

- [ ] **Step 3: Fix `README.md`**

3a. Fix the wrong path everywhere: replace all four occurrences of `script/Deploy.s.sol` (lines 237, 391, 398, 405) with `scripts/Deploy.s.sol` (there is no `script/` directory in this repo).

3b. Replace the mainnet + cross-VM block (current lines 401–421) — everything from `#### Mainnet Deployment:` through the end of the Cross-VM code fence — with:

````markdown
#### Mainnet Deployment:

```bash
# Deploy to mainnet
forge script scripts/Deploy.s.sol --broadcast --rpc-url $MAINNET_RPC_URL --verify
```

### Cross-VM Support

For cross-VM deployments (e.g., integrating with Solana), set the per-bridge
prover lists before running the deploy script:

```bash
# Deploy with cross-VM prover support
HYPER_CROSS_VM_PROVERS="0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef" \
  forge script scripts/Deploy.s.sol --broadcast --rpc-url $MAINNET_RPC_URL --verify
```
````

- [ ] **Step 4: Fix `CLAUDE.md`**

4a. In the `### Development` command list, replace:

```markdown
- `forge script script/Deploy.s.sol --broadcast --rpc-url $RPC_URL` - Deploy contracts
- `yarn deployCI` - CI deployment script
- `yarn semantic:pub` - Semantic release (local testing)
```

with:

```markdown
- `forge script scripts/Deploy.s.sol --broadcast --rpc-url $RPC_URL` - Deploy contracts

### Releases

- Releases are automated: on push to `main`, semantic-release computes the next
  version from conventional commits, rewrites contract `version()` functions and
  `package.json`, updates `CHANGELOG.md`, commits back as
  `chore(release): x.y.z [skip ci]`, and tags a GitHub release. No deploys, no
  npm publish. PR titles must be conventional commits (enforced in CI).
```

4b. Search CLAUDE.md for any other reference to `deployCI`, `semantic:pub`, or `script/Deploy.s.sol` and fix the same way:

```bash
grep -n "deployCI\|semantic:pub\|script/Deploy" CLAUDE.md
```

Expected after edits: no matches.

- [ ] **Step 5: Verify no dangling doc references remain**

```bash
grep -rn "deployRoutes\|deployCI\|semantic:pub\|createXOld\|script/Deploy.s.sol" \
  README.md CLAUDE.md scripts/README.md AGENTS.md
```

Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add README.md CLAUDE.md scripts/README.md CLAUDE/specs/deposit_address_userflow.md CLAUDE/specs/localprover_flows.md
git commit -m "docs: update deployment and release docs for new semantic-release flow"
```

(The `git mv` moves are already staged.)

---

### Task 5: Final verification sweep

**Files:** none created; possible small fixes only.

- [ ] **Step 1: Full test suite**

```bash
yarn build && yarn test
```

Expected: hardhat compile + hardhat tests + jest + forge tests all pass. (This is the repo's standard `yarn test`; it is slow — let it finish.)

- [ ] **Step 2: Lint/format check**

```bash
yarn lint
```

Expected: completes; if it reformats files, inspect with `git diff` — only files this plan touched may change. Commit any formatting fixes as `style: format` if needed.

- [ ] **Step 3: End-to-end release rehearsal (local, reverted)**

```bash
npx tsx scripts/release/update-versions.ts 3.9.9
npx prettier --write 'contracts/**/*.sol'
forge build
git diff --stat contracts/ package.json
git checkout -- contracts package.json
```

Expected: `forge build` succeeds on the rewritten sources; the diff touches only files containing `version()` (Semver.sol, TestProver.sol, TestMessageBridgeProver.sol) + package.json; checkout reverts cleanly.

- [ ] **Step 4: Confirm the working tree contains only intended changes**

```bash
git status --short
git log --oneline origin/main..HEAD
```

Expected: untracked `scripts/tron/*` files only; commit list = spec commit + plan commit + Tasks 1–4 commits (+ optional style commit).

- [ ] **Step 5: Report operational prerequisites to the user (do not act on them)**

Remind the user of the two human-action items from the spec before the first real release:
1. Branch protection on `main` must allow the release workflow's push (add `github-actions[bot]` to the bypass list, or provide an app/PAT token).
2. The `beta` branch and any repo secrets used only by the old pipeline (AWS role, VERIFICATION_KEYS, RELEASE_PAT, NPM_TOKEN in the release context) can be retired after merge — human decision.

---

## Self-Review Notes (already applied)

- Spec coverage: workflows (Task 2), version rewrite + granularity (Task 1), pipeline deletion + package.json prune (Task 3), orphan cleanup + doc fixes + doc moves (Tasks 3–4), dry-run + forge-build verification (Tasks 2/5). Branch-protection and prerelease-tag edge cases are surfaced as explicit check/report steps (Task 2 Step 5, Task 5 Step 5).
- Type consistency: `updateSolidityVersions(rootDir, version): string[]` and the CLI signature are defined in Task 1 and consumed verbatim in Task 2's `.releaserc.json` and Task 5's rehearsal.
- No placeholders: every file change includes full content or exact before/after text.
