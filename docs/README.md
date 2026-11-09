# Documentation

SlideBlaster documentation is scoped deliberately:

- Product, format, UX, service, and cross-cutting design belongs in `.META/design/`.
- Concise accepted semantic memory belongs in `.META/knowledge/`.
- Legacy `../../design/` and `../../knowledge/` remain read-only and searchable until their dedicated migration.
- Haskell implementation architecture lives in `architecture/`.
- Haskell implementation decisions live in `decisions/`.
- Versioned engine and host contracts live in `specs/`.
- Versioned executable contracts live in `specs/`.
- Reproducible operational procedures live in `runbooks/`.
- Time-bounded investigation lives in `research/`.

See [AGENTS.md](../AGENTS.md) for authority, acceptance, and supersession rules.

Operational development records live in [`.META`](../.META/README.md). The
accepted procedures are the [development](runbooks/development.md),
[worktree](runbooks/worktrees.md), and [release](runbooks/release.md) runbooks;
the durable rationale is [ADR 0006](decisions/0006-development-workflow.md).
