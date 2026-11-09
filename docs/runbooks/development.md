---
status: accepted
updated: 2026-07-27
---

# Development workflow

All normal work starts from local `dev`. Before editing, search
`.META/knowledge/` and, until migration completes, the preserved
`../knowledge/`; read affected contracts, inspect status, and classify user
gates under `AGENTS.md`.

## Start and record work

Every session captures the initiating agent prompt verbatim in `.prompt`. Pass a
reviewed prompt file, or use standard input without putting multiline content in
shell history:

```bash
./scripts/session/create.sh implementation "Capability title" - <<'PROMPT'
The exact initiating prompt given to the session-owning agent.
PROMPT

./scripts/session/create.sh research "Research question" /tmp/session.prompt
./scripts/session/create.sh maintenance "Maintenance task" /tmp/session.prompt
```

Do not place credentials or secrets in a session prompt. The generated ID is
`SB2-YYYYMMDD-NNN`; an explicitly coordinated ID is the optional fourth
argument. Registration requires a clean local `dev` tip.

Every session gets `.prompt`, `SESSION.md`, `STEERING.md`, and `REVIEW.md`.
Implementation adds `SPEC.md` and `SLICES.md`; research adds `RESEARCH.md`;
maintenance adds `MAINTENANCE.md`. Review and commit the complete session record
to `dev` before creating its worktree.

Validate with:

```bash
make metadata-validate
./scripts/session/validate.sh SB2-YYYYMMDD-NNN
```

## Specify artifacts and demonstration

For an implementation session, `SPEC.md` is the single contract for:

- the artifact or artifacts delivered;
- the functionality or fix the product owner can observe;
- exact launch or access instructions and revision;
- actions and expected observations;
- limitations and unavailable targets;
- automated acceptance evidence.

Do not duplicate a separate product-owner demonstration for every slice.
`SLICES.md` divides implementation and technical verification of that
specification.

Research and maintenance record an analogous observable report, reproduction,
diff, repository state, or before/after outcome in their type-specific plan.

## Record steering and research

Append material product-owner direction and its disposition to `STEERING.md`.
Clarify ambiguous interpretation. A steering item is not resolved merely because
an agent chose to defer it; the product owner must agree.

Keep each reproducible research run under:

```text
.META/research/<session-id>--<task-slug>--<agent-slug>--<run>/
```

For example:

```bash
./scripts/research/create.sh SB2-20260726-003 wasm-link-time kiro-verifier
```

Track concise reports and reproduction scripts; put bulky evidence in the
ignored `artifacts/` directory. Research becomes a contract only after promotion
to `.META/design/`, `.META/knowledge/`, an implementation document, or a test.

## Demonstrate, review, integrate, and close

After technical verification, explicitly ask the product owner:

1. whether they can observe the specified artifact and behaviour; and
2. whether it satisfies the specification or intended outcome.

Record both responses in `REVIEW.md`. Observation is not product acceptance and
silence is neither. Requested changes or rejection keep the session open.

After acceptance, present an exact PR, merge request, commit range, patch, or
local diff for product-owner review. Only an approved review unit may move to
integration. Completed work integrates into `dev`, never directly into `main`.
Record the full integration commit and post-integration checks.

Integration does not close the session. Ask explicitly whether the product owner
approves closing the named session and record the response. `closed` validates
only after observation, outcome acceptance, resolved steering, approved change
review, verified `dev` integration, and explicit closure approval.

Preserve unrelated work, never commit generated caches or local evidence, and
do not retire `../editor/` without a separate accepted decision. Releases are a
separate product-owner operation described in [release.md](release.md).
