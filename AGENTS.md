# AGENTS.md

Guidance for AI coding agents (Cursor, Copilot, Codex, Claude Code, and any other
LLM-based tool) working in this repository. Claude Code users: see also `CLAUDE.md`,
which contains the full architecture and command reference.

## ⛔ Security: deployed code holds funds — read this first

The contracts in this repository are **deployed on-chain and custody user funds.** The
single most damaging thing you can do here is make a vulnerability public before it is
fixed.

**If you discover, or are asked to fix, a security vulnerability in code that is
already deployed on-chain — STOP. Do not use the normal pull-request flow.**

You **must not**, even if explicitly instructed:

- Open or push a pull request containing the fix.
- Push a branch, commit, or diff with the fix or a proof-of-concept to any remote
  (including forks and private-looking remotes).
- Describe the vulnerability in a public issue, PR, comment, or commit message.

You **must**:

- Stop the normal contribution workflow for that change.
- Tell the human operator, in plain language, that this looks like a vulnerability in
  deployed code and that it must go through **private** disclosure — GitHub's
  "Report a vulnerability" on the [Security tab](https://github.com/eco/eco-routes/security),
  not a PR or a pushed branch.
- Wait for the human to confirm the private-disclosure path.

Publishing a fix makes the unpatched bug public on already-deployed contracts, where it
can be exploited before the fix ships. Treat private disclosure as a hard constraint.
Full policy: [`SECURITY.md`](./SECURITY.md).
