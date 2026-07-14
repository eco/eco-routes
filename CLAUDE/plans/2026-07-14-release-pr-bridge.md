# Release-PR Bridge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the push-to-main release flow (blocked by the org ruleset) with a release-PR bridge: an auto-refreshing `chore(release): x.y.z` PR that a human approves, after which a second workflow tags and publishes the GitHub release.

**Architecture:** `release-pr.yaml` (on push to main) computes the next version via semantic-release dry-run, rewrites versions with the existing `update-versions.ts`, updates `CHANGELOG.md` via conventional-changelog, and force-pushes an App-token-authored PR from the fixed branch `autorelease/next`. `release-tag.yaml` (on push to main) detects the merged release commit and creates the tag + GitHub release with plain `GITHUB_TOKEN`.

**Tech Stack:** GitHub Actions, semantic-release (analyzer + exec only), conventional-changelog-cli, tsx, existing `scripts/release/update-versions.ts`, `actions/create-github-app-token`, gh CLI (preinstalled on runners).

**Spec:** `CLAUDE/specs/2026-07-14-release-pr-bridge-design.md` (approved).

## Global Constraints

- Branch for this work: `cfebres/release-pr-bridge` (already created; spec committed).
- Commit messages: conventional format, NO co-author lines, NO Claude attribution. Do NOT push in this plan (push/PR happens at finish).
- The release branch name must be exactly `autorelease/next` — it must NOT match the org-ruleset glob `release*` (never rename it to anything starting with "release").
- `scripts/release/update-versions.ts` and its tests are NOT modified by this plan.
- The baseline guard logic must be preserved verbatim (stable tag `>= v2.8.17` reachable, else abort).
- Workflow shell must never interpolate `${{ github.event.head_commit.message }}` directly into `run:` — always via `env:`.
- No org ruleset changes; no npm publishing.
- Untracked `scripts/tron/*` files: never touch.

---

### Task 1: Slim `.releaserc.json` to analyzer + version-file output

**Files:**
- Modify (full replace): `.releaserc.json`

**Interfaces:**
- Produces: running `npx semantic-release --dry-run --no-ci` writes the computed next version (bare `x.y.z`) to `.release-next-version` in the repo root when a release is due, and writes nothing when no releasable commits exist. Tasks 2's workflow relies on exactly this file name and behavior.

- [ ] **Step 1: Replace `.releaserc.json`**

Full new content (removes `changelog`, `git`, `github` plugins and the old prepareCmd/successCmd — their jobs move into the workflows; keeps the analyzer rules identical):

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
    [
      "@semantic-release/exec",
      {
        "verifyReleaseCmd": "printf '%s' \"${nextRelease.version}\" > .release-next-version"
      }
    ]
  ]
}
```

- [ ] **Step 2: Verify version computation locally**

```bash
rm -f .release-next-version
GITHUB_TOKEN=$(gh auth token) npx semantic-release --dry-run --no-ci \
  --branches "$(git rev-parse --abbrev-ref HEAD)" 2>&1 | grep -E "Found git tag|next release"
cat .release-next-version && echo
```

Expected: `Found git tag v2.9.0 ...` (or `v2.10.0` if release PR #414 merged since), `The next release version is 2.10.0` (or higher), and `.release-next-version` containing exactly that bare version. Then clean up:

```bash
rm -f .release-next-version
```

- [ ] **Step 3: Add `.release-next-version` to `.gitignore`**

Append to `.gitignore`:

```
# release-pr workflow scratch file
.release-next-version
```

- [ ] **Step 4: Commit**

```bash
git add .releaserc.json .gitignore
git commit -m "chore: slim semantic-release config to version computation only"
```

---

### Task 2: `release-pr.yaml` workflow (replaces `release.yaml`)

**Files:**
- Create: `.github/workflows/release-pr.yaml`
- Delete: `.github/workflows/release.yaml`

**Interfaces:**
- Consumes: `.release-next-version` behavior from Task 1; existing CLI `npx tsx scripts/release/update-versions.ts <x.y.z>`.
- Produces: an open PR from branch `autorelease/next` titled `chore(release): x.y.z` whose body is the release notes. Task 3 relies on the squash-merge of this PR producing a main head commit with message `chore(release): x.y.z`.

- [ ] **Step 1: Delete the old workflow**

```bash
git rm .github/workflows/release.yaml
```

- [ ] **Step 2: Create `.github/workflows/release-pr.yaml`**

Full content:

```yaml
name: Release PR

on:
  push:
    branches: [main]
  workflow_dispatch:
    inputs:
      dry-run:
        description: "Compute and print without pushing or opening a PR"
        type: boolean
        default: true

concurrency:
  group: release-pr
  cancel-in-progress: true

permissions:
  contents: read

jobs:
  release-pr:
    name: Build or refresh the release PR
    runs-on: ubuntu-latest
    env:
      HEAD_MSG: ${{ github.event.head_commit.message || '' }}
      DRY_RUN: ${{ github.event_name == 'workflow_dispatch' && inputs.dry-run }}
    steps:
      # The push that lands a merged release PR is handled by release-tag.yaml
      - name: Skip release commits
        id: skip
        run: |
          FIRST_LINE=$(printf '%s' "$HEAD_MSG" | head -1)
          if printf '%s' "$FIRST_LINE" | grep -qE '^chore\(release\): [0-9]+\.[0-9]+\.[0-9]+$'; then
            echo "skip=true" >> "$GITHUB_OUTPUT"
            echo "Head commit is a release commit; nothing to do."
          else
            echo "skip=false" >> "$GITHUB_OUTPUT"
          fi

      - uses: actions/checkout@v4.2.2
        if: steps.skip.outputs.skip == 'false'
        with:
          fetch-depth: 0 # semantic-release needs full history + tags

      # Guard against computing from a broken version baseline: without a
      # stable tag >= v2.8.17 reachable from main, semantic-release would
      # compute the next version from the legacy v1.x line.
      - name: Verify release baseline tag
        if: steps.skip.outputs.skip == 'false'
        run: |
          BASELINE=$(git tag --merged HEAD | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
          echo "Highest reachable stable tag: ${BASELINE:-none}"
          if [ "$(printf '%s\n' "v2.8.17" "$BASELINE" | sort -V | tail -1)" != "$BASELINE" ] || [ -z "$BASELINE" ]; then
            echo "::error::No stable tag >= v2.8.17 is reachable from this branch. Create the baseline tag before releasing (see scripts/README.md, Releases section)."
            exit 1
          fi

      - uses: actions/setup-node@v4.1.0
        if: steps.skip.outputs.skip == 'false'
        with:
          node-version-file: ".nvmrc"
          cache: "yarn"

      - name: Install dependencies
        if: steps.skip.outputs.skip == 'false'
        run: yarn install --frozen-lockfile

      - name: Compute next version
        if: steps.skip.outputs.skip == 'false'
        id: version
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          rm -f .release-next-version
          npx semantic-release --dry-run
          if [ ! -s .release-next-version ]; then
            echo "No releasable commits since the last release; leaving any open release PR as-is."
            echo "version=" >> "$GITHUB_OUTPUT"
          else
            VERSION=$(cat .release-next-version)
            echo "Next version: $VERSION"
            echo "version=$VERSION" >> "$GITHUB_OUTPUT"
          fi

      - name: Rewrite versions and changelog
        if: steps.skip.outputs.skip == 'false' && steps.version.outputs.version != ''
        env:
          VERSION: ${{ steps.version.outputs.version }}
        run: |
          npx tsx scripts/release/update-versions.ts "$VERSION"
          # package.json now carries the next version, which conventional-changelog
          # uses for the new section header it prepends to CHANGELOG.md
          npx conventional-changelog -p angular -i CHANGELOG.md -s
          npx conventional-changelog -p angular > .release-notes.md
          echo "--- release notes ---"
          cat .release-notes.md

      - name: Mint App token
        if: steps.skip.outputs.skip == 'false' && steps.version.outputs.version != '' && env.DRY_RUN != 'true'
        id: app-token
        uses: actions/create-github-app-token@v1
        with:
          app-id: ${{ secrets.RELEASE_BOT_APP_ID }}
          private-key: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}

      - name: Push release branch and open/refresh PR
        if: steps.skip.outputs.skip == 'false' && steps.version.outputs.version != '' && env.DRY_RUN != 'true'
        env:
          VERSION: ${{ steps.version.outputs.version }}
          GH_TOKEN: ${{ steps.app-token.outputs.token }}
        run: |
          git config user.name "eco-release-bot[bot]"
          git config user.email "eco-release-bot[bot]@users.noreply.github.com"
          git checkout -B autorelease/next
          git add package.json CHANGELOG.md 'contracts/*.sol' 'contracts/**/*.sol'
          git commit -m "chore(release): $VERSION"
          git remote set-url origin "https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
          git push --force origin autorelease/next

          EXISTING=$(gh pr list --head autorelease/next --state open --json number --jq '.[0].number // empty')
          if [ -n "$EXISTING" ]; then
            gh pr edit "$EXISTING" --title "chore(release): $VERSION" --body-file .release-notes.md
            echo "Refreshed release PR #$EXISTING to $VERSION"
          else
            gh pr create --base main --head autorelease/next \
              --title "chore(release): $VERSION" --body-file .release-notes.md
            echo "Opened release PR for $VERSION"
          fi

      - name: Dry-run summary
        if: steps.skip.outputs.skip == 'false' && steps.version.outputs.version != '' && env.DRY_RUN == 'true'
        env:
          VERSION: ${{ steps.version.outputs.version }}
        run: |
          echo "DRY RUN: would open/refresh release PR 'chore(release): $VERSION' from autorelease/next"
          git status --short
```

- [ ] **Step 3: Validate the YAML**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/release-pr.yaml')); print('YAML OK')"
```

Expected: `YAML OK`.

- [ ] **Step 4: Rehearse the compute + rewrite steps locally**

```bash
rm -f .release-next-version .release-notes.md
GITHUB_TOKEN=$(gh auth token) npx semantic-release --dry-run --no-ci \
  --branches "$(git rev-parse --abbrev-ref HEAD)" > /dev/null 2>&1 || true
VERSION=$(cat .release-next-version)
echo "computed: $VERSION"
npx tsx scripts/release/update-versions.ts "$VERSION"
npx conventional-changelog -p angular -i CHANGELOG.md -s
npx conventional-changelog -p angular > .release-notes.md
head -5 CHANGELOG.md
head -5 .release-notes.md
git checkout -- CHANGELOG.md package.json contracts
rm -f .release-next-version .release-notes.md
```

Expected: a version like `2.10.0` computed; `CHANGELOG.md` head shows a new `## [2.10.0]` section; `.release-notes.md` contains the same section; revert leaves `git status --short` clean (plus untracked tron files). NOTE: `conventional-changelog-cli` is added to devDependencies in Task 4 — if `npx conventional-changelog` prompts to install here, accept the ad-hoc install for the rehearsal (Task 4 pins it).

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/release-pr.yaml
git commit -m "ci: replace push-to-main release with release-PR workflow"
```

(The `git rm` from Step 1 is already staged and lands in this commit.)

---

### Task 3: `release-tag.yaml` workflow

**Files:**
- Create: `.github/workflows/release-tag.yaml`

**Interfaces:**
- Consumes: a main head commit with message `chore(release): x.y.z` (the squash-merge of Task 2's PR), whose tree has `package.json.version == x.y.z`.
- Produces: tag `vx.y.z` on that commit and a published GitHub release named `vx.y.z`.

- [ ] **Step 1: Create `.github/workflows/release-tag.yaml`**

Full content:

```yaml
name: Release Tag

on:
  push:
    branches: [main]
  workflow_dispatch:
    inputs:
      version:
        description: "Version to tag/release (x.y.z) if the automatic detection missed it"
        type: string
        required: true

permissions:
  contents: write

jobs:
  release-tag:
    name: Tag and publish release
    runs-on: ubuntu-latest
    env:
      HEAD_MSG: ${{ github.event.head_commit.message || '' }}
      DISPATCH_VERSION: ${{ inputs.version || '' }}
    steps:
      - name: Detect release commit
        id: detect
        run: |
          if [ -n "$DISPATCH_VERSION" ]; then
            VERSION="$DISPATCH_VERSION"
          else
            FIRST_LINE=$(printf '%s' "$HEAD_MSG" | head -1)
            VERSION=$(printf '%s' "$FIRST_LINE" | sed -nE 's/^chore\(release\): ([0-9]+\.[0-9]+\.[0-9]+)$/\1/p')
          fi
          if [ -z "$VERSION" ]; then
            echo "Not a release commit; nothing to do."
          else
            echo "Release version: $VERSION"
          fi
          echo "version=$VERSION" >> "$GITHUB_OUTPUT"

      - uses: actions/checkout@v4.2.2
        if: steps.detect.outputs.version != ''

      - name: Verify package.json matches
        if: steps.detect.outputs.version != ''
        env:
          VERSION: ${{ steps.detect.outputs.version }}
        run: |
          PKG_VERSION=$(node -p "require('./package.json').version")
          if [ "$PKG_VERSION" != "$VERSION" ]; then
            echo "::error::package.json version ($PKG_VERSION) does not match release version ($VERSION). Refusing to tag."
            exit 1
          fi

      - name: Create and push tag
        if: steps.detect.outputs.version != ''
        env:
          VERSION: ${{ steps.detect.outputs.version }}
        run: |
          if git ls-remote --exit-code --tags origin "refs/tags/v$VERSION" > /dev/null 2>&1; then
            echo "Tag v$VERSION already exists on origin; skipping tag creation."
          else
            git config user.name "github-actions[bot]"
            git config user.email "github-actions[bot]@users.noreply.github.com"
            git tag "v$VERSION" "$GITHUB_SHA"
            git push origin "v$VERSION"
          fi

      - name: Publish GitHub release
        if: steps.detect.outputs.version != ''
        env:
          VERSION: ${{ steps.detect.outputs.version }}
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          if gh release view "v$VERSION" > /dev/null 2>&1; then
            echo "Release v$VERSION already exists; skipping."
            exit 0
          fi
          # Prefer the merged release PR's body as the notes
          gh api "repos/${GITHUB_REPOSITORY}/commits/${GITHUB_SHA}/pulls" \
            --jq '.[0].body // empty' > .release-notes.md || true
          if [ ! -s .release-notes.md ]; then
            # Fallback: extract the top section of CHANGELOG.md
            awk '/^##? /{ n++ } n==1' CHANGELOG.md > .release-notes.md
          fi
          gh release create "v$VERSION" --title "v$VERSION" \
            --target "$GITHUB_SHA" --notes-file .release-notes.md
```

- [ ] **Step 2: Validate the YAML**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/release-tag.yaml')); print('YAML OK')"
```

Expected: `YAML OK`.

- [ ] **Step 3: Test the version-detection sed expression locally**

```bash
printf '%s' "chore(release): 2.10.0" | sed -nE 's/^chore\(release\): ([0-9]+\.[0-9]+\.[0-9]+)$/\1/p'
printf '%s' "chore(release): 2.10.0 [skip ci]" | sed -nE 's/^chore\(release\): ([0-9]+\.[0-9]+\.[0-9]+)$/\1/p'
printf '%s' "feat: something" | sed -nE 's/^chore\(release\): ([0-9]+\.[0-9]+\.[0-9]+)$/\1/p'
```

Expected: first prints `2.10.0`; second and third print nothing (the second intentionally — new release commits carry no `[skip ci]` suffix; only exact titles match).

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/release-tag.yaml
git commit -m "ci: add release-tag workflow to publish after release PR merge"
```

---

### Task 4: Dependencies and documentation

**Files:**
- Modify: `package.json` (devDependencies)
- Modify: `scripts/README.md` (Releases + go-live sections)
- Modify: `CLAUDE.md` (Releases bullets)

- [ ] **Step 1: Update devDependencies**

Remove from `package.json` devDependencies: `@semantic-release/changelog`, `@semantic-release/git`, `@semantic-release/github`.
Add: `"conventional-changelog-cli": "^5.0.0"`.
Keep: `semantic-release`, `@semantic-release/exec`.

```bash
yarn install
```

Expected: lockfile updates without errors.

- [ ] **Step 2: Verify nothing references the removed plugins**

```bash
grep -rn "semantic-release/changelog\|semantic-release/git\|semantic-release/github" \
  .releaserc.json .github/ scripts/ package.json | grep -v conventional
```

Expected: no output.

- [ ] **Step 3: Rewrite the Releases section of `scripts/README.md`**

Replace everything from the `## Releases` heading through the end of the "Patching a previous major" section with:

```markdown
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
```

- [ ] **Step 4: Update the `### Releases` section of `CLAUDE.md`**

Replace the existing `### Releases` bullet list with:

```markdown
### Releases

- Releases flow through an auto-refreshing release PR (`autorelease/next`
  branch, title `chore(release): x.y.z`) created by
  `.github/workflows/release-pr.yaml` on each push to `main`. A human
  approves and squash-merges it; `.github/workflows/release-tag.yaml` then
  tags `vx.y.z` and publishes the GitHub release. No direct pushes to
  `main`; no deploys; no npm publish. PR titles must be conventional
  commits (enforced in CI). Details:
  `CLAUDE/specs/2026-07-14-release-pr-bridge-design.md` and
  `scripts/README.md`.
```

(Remove the old bullets describing the push-back flow and the v2.8.18
baseline prerequisite — the baseline tag v2.9.0 already exists on `main`;
keep no stale go-live instructions.)

- [ ] **Step 5: Verify docs consistency and run tests**

```bash
grep -rn "chore(release): x.y.z \[skip ci\]\|v3.3.0\|v2.8.18" scripts/README.md CLAUDE.md
yarn test:ts
```

Expected: no grep matches (no stale flow descriptions); jest 9/9 passing.

- [ ] **Step 6: Commit**

```bash
git add package.json yarn.lock scripts/README.md CLAUDE.md
git commit -m "docs: document release-PR flow and prune moved semantic-release plugins"
```

---

### Task 5: Verification sweep and rollout handoff

**Files:** none created; checks only.

- [ ] **Step 1: Full verification**

```bash
yarn build && yarn test:ts && forge test -q 2>&1 | tail -2
python3 -c "import yaml,glob; [yaml.safe_load(open(f)) for f in glob.glob('.github/workflows/*.y*ml')]; print('all workflows parse')"
git log --oneline origin/main..HEAD
```

Expected: build + jest (9/9) + forge (567+ passing, 0 failed) green; all workflow files parse; commit list = spec + Tasks 1–4 commits.

- [ ] **Step 2: End-to-end rehearsal of the full release-PR computation**

```bash
rm -f .release-next-version .release-notes.md
GITHUB_TOKEN=$(gh auth token) npx semantic-release --dry-run --no-ci \
  --branches "$(git rev-parse --abbrev-ref HEAD)" > /dev/null 2>&1 || true
VERSION=$(cat .release-next-version); echo "version: $VERSION"
npx tsx scripts/release/update-versions.ts "$VERSION"
npx conventional-changelog -p angular -i CHANGELOG.md -s
forge build
git checkout -- CHANGELOG.md package.json contracts
rm -f .release-next-version .release-notes.md
git status --short
```

Expected: version computed, rewrite + changelog + `forge build` succeed, tree back to clean (only untracked `scripts/tron/*`).

- [ ] **Step 3: Report the rollout checklist to the user (do not act on it)**

Output verbatim:

1. Org owner: create GitHub App `eco-release-bot` (permissions: Contents
   read/write, Pull requests read/write; installed on eco/eco-routes only)
   and add repo secrets `RELEASE_BOT_APP_ID` + `RELEASE_BOT_PRIVATE_KEY`.
2. Repo admin: confirm squash-merge commit message defaults to PR title
   (Settings → General → Pull Requests).
3. Merge the bridge PR.
4. Close release PR #414 if still open — the first `release-pr.yaml` run
   regenerates the v2.10.0 release PR through the new machinery.
5. Approve + squash-merge the generated release PR; verify tag `v2.10.0`
   and its GitHub release appear via `release-tag.yaml`.

---

## Self-Review Notes (already applied)

- Spec coverage: skip guard, baseline guard, dry-run version file, notes
  generation, rewrite, App-token PR (Task 2); tag + release + dispatch
  recovery + idempotency checks (Task 3); config slim (Task 1); deps + docs
  (Task 4); rehearsal + rollout (Task 5). Failure modes from the spec map to:
  mangled squash title → Task 3 dispatch input; rejected PR → recreated (no
  state to clean); rapid pushes → concurrency group; zero/wrong rewrite →
  update-versions.ts guards; missing App secrets → token step fails loudly.
- Type consistency: `.release-next-version` and `.release-notes.md` names
  match across Tasks 1/2/3/5; `autorelease/next` and
  `chore(release): x.y.z` (no `[skip ci]`) match across Tasks 2/3/4.
- No placeholders: full file contents for all three changed/created
  workflows/configs; exact commands with expected output throughout.
