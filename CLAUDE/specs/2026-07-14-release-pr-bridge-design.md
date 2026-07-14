# Release-PR Bridge: Releasing Without Pushing to main

**Date:** 2026-07-14
**Status:** Approved
**Supersedes:** the push-to-main release flow from
`2026-07-08-semver-release-design.md` (which remains accurate for everything
else: version rewriting semantics, granularity, cleanup, test strategy).

## Problem

The semantic-release flow shipped in PR #410 pushes a release commit directly
to `main`. The org-level ruleset "Default branch protection" requires all
changes to `main` (and `refs/heads/release*`) to arrive via an approved pull
request, with no bypass actors — and the team does not want to weaken that
org-wide setting. Empirically verified: the workflow's `GITHUB_TOKEN` push,
a repo admin's direct push, and `gh pr merge --admin` are all rejected
(GH013). v2.10.0 had to be released by hand through a PR (#414).

release-please was evaluated and rejected: its release branch name
(`release-please--branches--main`) is hardcoded and matches the protected
`release*` pattern, so its own branch force-pushes would be blocked; its
annotation-based version rewriting (`x-release-please-version` comments in
contract source) was also declined.

## Decisions

1. **Custom release-PR bridge**: releases flow through a normal, approved PR
   — the same mechanism the ruleset mandates for everything else.
2. **GitHub App token** (not a PAT, not a bypass): an org owner creates a
   minimal App; the workflow mints short-lived tokens. App-authored events
   trigger CI, so the release PR's required checks run.
3. **No annotations in contracts**: version rewriting stays in the existing
   `scripts/release/update-versions.ts` (with its 9 tests and
   canonical-Semver.sol guard).
4. **Auto-refresh**: while a release PR is open, every new push to `main`
   recomputes and force-pushes it, so the PR always reflects what will
   actually be released.

## Architecture

Two workflows replace `.github/workflows/release.yaml`:

### 1. `release-pr.yaml` — build/refresh the release PR

Trigger: `push` to `main` (plus `workflow_dispatch` with a `dry-run` input
for testing). Concurrency group `release-pr` (cancel in-progress).

Steps:

1. **Skip guard**: exit successfully if the head commit message matches
   `^chore\(release\): \d+\.\d+\.\d+$` (that push belongs to
   `release-tag.yaml`).
2. **Baseline guard**: unchanged from today — abort unless a stable tag
   `>= v2.8.17` is reachable.
3. **Compute next version**: `npx semantic-release --dry-run` with the
   slimmed `.releaserc.json`; an `@semantic-release/exec`
   `verifyReleaseCmd` writes `${nextRelease.version}` to a temp file.
   If semantic-release reports no release (only non-releasable commits),
   exit successfully without touching any PR.
4. **Generate notes**: `npx conventional-changelog -p angular` for the
   commits since the last tag (same preset as the analyzer).
5. **Rewrite versions**: `npx tsx scripts/release/update-versions.ts <next>`
   (existing script, unchanged), prepend the generated section to
   `CHANGELOG.md`.
6. **Commit and push**: commit as `chore(release): x.y.z`, force-push to the
   fixed branch **`autorelease/next`** (deliberately does NOT match the
   protected `release*` glob), using the App token.
7. **Create-or-update the PR**: title `chore(release): x.y.z` (retitled on
   refresh), body = generated release notes. App-authored, so `ci.yaml` and
   the required checks run against the rewritten source — a stronger gate
   than the old flow, which tested before rewriting.

In `dry-run` mode (workflow_dispatch), steps 6–7 print instead of push.

### 2. `release-tag.yaml` — finish the release after merge

Trigger: `push` to `main`, plus `workflow_dispatch` with a `version` input
as the recovery path.

Steps:

1. Exit successfully unless the head commit message matches
   `^chore\(release\): (\d+\.\d+\.\d+)$` (or a version was supplied via
   dispatch).
2. Sanity check: `package.json` version at that commit equals the parsed
   version.
3. Tag `vx.y.z` on the head commit and push the tag. Plain `GITHUB_TOKEN`
   suffices: tag pushes are not covered by the branch ruleset (the tag
   ruleset "Npm Pulish" is disabled), and no workflows trigger on tags.
4. Create the GitHub release: notes taken from the merged PR's body (via
   the commit's associated pull request), falling back to the new
   `CHANGELOG.md` section.

### Kept from the current setup

- `scripts/release/update-versions.ts` + its Jest tests (all 9) — unchanged.
- Baseline guard logic (moves into `release-pr.yaml`).
- `pr-title-check.yml` (squash commits must stay conventional — the release
  flow itself depends on the `chore(release):` squash title).
- Semver-shape test assertions (`BaseTest._assertValidSemver`).

### Changed / removed

- `.github/workflows/release.yaml` — deleted (replaced by the two above).
- `.releaserc.json` — slimmed to `commit-analyzer` + `release-notes-generator`
  + `exec` (verifyReleaseCmd only). The `changelog`, `git`, and `github`
  plugins are removed; their jobs moved into the workflows.
- devDependencies: remove `@semantic-release/changelog`,
  `@semantic-release/git`, `@semantic-release/github`; add
  `conventional-changelog-cli`. Keep `semantic-release` +
  `@semantic-release/exec`.
- Docs: `scripts/README.md` Releases section and `CLAUDE.md` Releases bullet
  rewritten for the PR-based flow (including: squash-merge must default to
  PR title; each release requires one human approval).

## Failure modes

| Failure | Behavior |
|---|---|
| Squash title edited so it no longer matches `chore(release): x.y.z` | No tag/release created — visible gap; recover with `release-tag.yaml` workflow_dispatch + version input. |
| Release PR rejected/closed | Nothing released; next push to `main` recreates it fresh. |
| Rapid pushes to `main` | Concurrency group cancels the older `release-pr` run; the newest wins. |
| Version-rewrite produces zero/wrong files | `update-versions.ts` fails loudly (existing zero-rewrite + canonical-file guards) and the PR is never opened/updated. |
| App secrets missing/expired | `release-pr.yaml` fails at token minting — loud, nothing half-done. |

## One-time prerequisites (org owner; NOT a ruleset change)

1. Create a GitHub App (suggested name `eco-release-bot`): permissions
   Contents read/write + Pull requests read/write; install it on
   `eco/eco-routes` only.
2. Add repo secrets `RELEASE_BOT_APP_ID` and `RELEASE_BOT_PRIVATE_KEY`.
   The workflow mints tokens with `actions/create-github-app-token`.
3. Confirm the repo's squash-merge commit message setting is
   "Default to pull request title".

## Rollout

1. Land the App + secrets (blocking prereq).
2. Merge the bridge PR (this design's implementation).
3. If release PR #414 (v2.10.0) is still open, close it — the first
   `release-pr.yaml` run regenerates the same release through the new
   machinery, validating it end-to-end. If #414 already merged, the bridge
   simply computes the next version from `v2.10.0`.
4. Approve and squash-merge the generated release PR; verify the tag and
   GitHub release appear.

## Testing

- Existing `update-versions.ts` Jest tests carry over untouched.
- `release-pr.yaml` dry-run mode (workflow_dispatch) exercises version
  computation, notes generation, and rewriting without pushing.
- The release PR itself runs the full required-check suite against the
  rewritten source before any human approves.
- `release-tag.yaml`'s workflow_dispatch doubles as its manual test and
  recovery path.

## Out of scope

- npm publishing (unchanged: separate, deliberate step).
- Org ruleset edits of any kind.
- Deleting the 18 orphaned GitHub Releases and repointing the npm `latest`
  dist-tag (registry-side decisions, parked with MSevey).
