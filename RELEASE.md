# Releasing eco-routes

Releases are automated but **gated by an approved pull request** — there are no
direct pushes to `main` (the org branch-protection ruleset forbids them). Each
release is a normal PR a human approves and squash-merges.

## How a release happens

1. On every push to `main`, `.github/workflows/release-pr.yaml`:
   - computes the next version from the conventional commits since the last
     tag (`fix:` → patch, `feat:` → minor, `BREAKING CHANGE` → major),
   - rewrites `version()` in the contracts and bumps `package.json`
     (`scripts/release/update-versions.ts`),
   - regenerates `CHANGELOG.md`,
   - force-pushes an **auto-refreshing** PR from the fixed branch
     `autorelease/next`, titled `chore(release): x.y.z`.

   While that PR is open, new commits to `main` refresh its version and notes.

2. A human reviews, approves, and **squash-merges** the release PR. Required
   CI checks run against the rewritten source before merge.

3. `.github/workflows/release-tag.yaml` detects the merged release commit on
   `main`, tags `vx.y.z`, and publishes the GitHub release (PR body as notes,
   `CHANGELOG.md` as fallback).

PR titles must follow the conventional-commit format (enforced by
`.github/workflows/pr-title-check.yml`), because the squash-merge commit is
what the release flow analyzes and detects.

## One-time setup

- **GitHub App** — the release PR is authored with a GitHub App token
  (`RELEASE_BOT_APP_ID` / `RELEASE_BOT_PRIVATE_KEY` repo secrets) so that CI
  triggers on it; the default `GITHUB_TOKEN` cannot trigger workflows on its
  own PRs. The App needs only **Contents** and **Pull requests** read/write on
  this repository. It is **not** a branch-protection bypass.
- **Merge setting** — the repository's squash-merge commit message must default
  to the pull request title (Settings → General → Pull Requests), so the merged
  commit keeps the `chore(release): x.y.z` subject the tagging workflow detects.

## Recovery

If a squash title is ever edited so the tagging workflow misses it, run
`.github/workflows/release-tag.yaml` manually via **workflow_dispatch** with the
version (`x.y.z`) as input. It locates the release commit by message and tags
it.

## Notes and constraints

- **Baseline guard** — `release-pr.yaml` refuses to compute a version unless a
  stable tag `>= v2.8.17` is reachable from `main`. This prevents computing the
  next version from the legacy v1.x tag line.
- **Bytecode impact** — the version string is compiled into the contracts, so
  every release changes contract bytecode and therefore the CREATE2
  deterministic deployment addresses of subsequent deployments.
- **Out of scope** — contract deployment and npm publishing are deliberately
  NOT part of the release flow; they are separate, explicit steps.

### Patching a previous major

Releases bump off `main`, so once a major lands there is no branch to patch the
previous major in production. When `main` bumps to a new major (e.g.
`v2.x → v3.x`), cut a `release-v2.x` branch from the last `v2.x` tag so
production fixes can be cherry-picked and released there while `main` carries
the latest line.
