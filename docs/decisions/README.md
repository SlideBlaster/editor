---
status: accepted
updated: 2026-07-23
---

# Haskell implementation decisions

This directory records durable implementation decisions scoped to
`slideBlaster2`.

Product, format, UX, service, security, or other cross-cutting decisions belong
in `.META/design/`. If an implementation decision changes a shared contract,
create or update the product-design decision and link it here. Legacy
`../../design/decisions/` remains read-only until its dedicated migration.

An ADR is:

- `proposed` while under review;
- `accepted` after the authority described in `AGENTS.md` accepts it;
- `superseded` rather than deleted when replaced.

Git contains history; ADRs do not contain changelogs.

Current workflow decision:
[0006-development-workflow.md](0006-development-workflow.md).
