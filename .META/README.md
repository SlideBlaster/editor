# SlideBlaster 2 repository control plane

`.META` contains the repository-local product design, semantic knowledge,
development records, source provenance, and reproducible research used to steer
SlideBlaster 2. Product behaviour still requires executable implementation
contracts and tests; `.META` records authority and intent rather than replacing
them.

Tracked here:

- authoritative product, format, UX, service, and cross-cutting design;
- concise accepted semantic knowledge;
- source manifests, never third-party source checkouts;
- session prompts, templates, durable records, steering, review, and closure;
- concise research reports and reusable research templates.

Ignored here:

- local source checkouts, including `sources/drawio/`;
- bulky research artifacts and generated evidence;
- per-worktree or per-session transient state.

The legacy `../design/` and `../knowledge/` trees remain untouched pending a
dedicated migration session. Search both old and new locations until that
migration is reviewed, indexed, and accepted; deletion requires separate
approval.

Session IDs have the form `SB2-YYYYMMDD-NNN`. Research runs live at
`research/<session-id>--<task-slug>--<agent-slug>--<run>/`. See
[`design/README.md`](design/README.md),
[`knowledge/README.md`](knowledge/README.md),
[`sessions/README.md`](sessions/README.md),
[`research/README.md`](research/README.md), the
[development runbook](../docs/runbooks/development.md), and the
[workflow ADR](../docs/decisions/0006-development-workflow.md).
