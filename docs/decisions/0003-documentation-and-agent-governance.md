---
status: superseded
updated: 2026-07-27
---

# 0003. Documentation and agent governance

This proposal placed shared design in `../design/` and semantic memory in
`../knowledge/`. The product owner instead accepted `.META/design/` and
`.META/knowledge/` as the repository-local destination authorities, with a
separately reviewed safe migration of the legacy trees.

The role model, one-writer rule, evidence-based consensus, user gates, Haddock
contracts, and vertical-slice delivery remain adopted through `AGENTS.md`.
Repository authority, session evidence, and closure are governed by
[ADR 0006](0006-development-workflow.md).
