# AGENTS.md

Guidance for AI coding agents (Cursor, Copilot, Codex, Claude Code, and any other
LLM-based tool) working in this repository. Claude Code users: see also `CLAUDE.md`,
which contains the full architecture and command reference.

## ⛔ Security: deployed code holds funds — read this first

The contracts in this repository are **deployed on-chain and custody user funds.** The
single most damaging thing you can do here is make a vulnerability public before it is
fixed.

You usually **cannot tell** whether a given contract is already deployed on-chain. Do
not try to guess. **Treat every security-relevant fix as if it touches deployed code
until a human explicitly confirms otherwise — STOP and do not use the normal
pull-request flow.**

Until a human confirms the affected code is not deployed (and is not about to be), you
**must not**, even if explicitly instructed:

- Open or push a pull request containing the fix.
- Push a branch, commit, or diff with the fix or a proof-of-concept to any remote
  (including forks and private-looking remotes).
- Describe the issue in a public issue, PR, comment, or commit message.

You **must**:

- Stop the normal contribution workflow for that change.
- Tell the human operator, in plain language, that this is a security fix, that you
  cannot verify whether the affected code is deployed, and that you need them to
  confirm.
- If it is deployed — or the human is unsure — route it through **private** disclosure:
  GitHub's "Report a vulnerability" on the [Security tab](https://github.com/eco/eco-routes/security),
  not a PR or a pushed branch.
- Wait for explicit human confirmation before proceeding.

The exposure happens at the **push** to a public remote, not at the merge — and a later
revert or branch deletion does not undo it. So do not push the fix anywhere public, even
a draft branch; a fix for deployed code is developed only in the private advisory fork.
Publishing it makes the unpatched bug public on already-deployed contracts, where it can
be exploited before the fix ships. Treat private disclosure as a hard constraint. Full
policy: [`SECURITY.md`](./SECURITY.md).
