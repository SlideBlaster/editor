# SB2-20260726-001 specification

## User-visible capability

A developer or product owner can register typed work with its initiating prompt,
run it in a correctly based external worktree, inspect durable steering and
verification, explicitly observe and accept the specified outcome, review the
exact change unit, integrate only to `dev`, and explicitly approve closure and
release promotion.

## Contracts and invariants

- Authored project work is preserved at `4c39b9a`.
- `.META` is the repository design, knowledge, evidence, and session control
  plane while legacy design/knowledge migration remains separately gated.
- Session prompt, steering, review, and closure records are tracked.
- Artifact and observable functionality are accepted once per specification,
  not independently per slice.
- Rejection or requested changes keep a session open.
- Only product-owner responses permit review approval and closure.
- Session branches descend from their immutable `dev` registration commit.
- Completed work integrates only into `dev`; every `main` advance is a release.
- Workflow scripts never push.

## Included and excluded scope

Included: dependency-free templates, metadata validation, worktree helpers,
research records, release checks, documentation, state validation, and migration
scaffolding. Excluded: product behavior, dependency/CI setup, migration or
deletion of legacy design/knowledge, automatic push, and automatic authority.

## Failure and stale-state behaviour

Helpers fail before mutation on invalid state. Advanced session states fail
validation unless their product-owner and integration prerequisites are
recorded. Worktree creation and release promotion require explicit confirmation.

## Delivery artifacts

| Artifact | Kind | Location or access | Purpose |
| --- | --- | --- | --- |
| Governance | document | `AGENTS.md`, ADR 0006, runbooks | Authority and procedure |
| Repository control plane | tracked files | `.META/` | Design/knowledge destinations and durable session evidence |
| Session helpers | executable Bash | `scripts/session/` | Prompt capture, validation, worktrees |
| Research helper | executable Bash | `scripts/research/create.sh` | Reproducible run identity |
| Release helpers | executable Bash | `scripts/release/` | Version checks and explicit local promotion |
| Verification evidence | scripts/results | `.META/research/SB2-20260726-001--workflow-validation--kiro-verifier--01/` | Reproduce workflow behavior |

The exact artifact revision remains the uncommitted `dev` worktree based at
`4c39b9a` until a product-owner-approved review unit is committed.

## Product-owner demonstration

1. Read the authority and lifecycle in `.META/README.md`, this specification,
   ADR 0006, and the development runbook.
2. Run the repository-local validation recipe and isolated fixture suite.
3. Inspect a fixture-created `.prompt`, typed records, steering/review files,
   worktree ancestry behavior, and release preview.
4. Change a fixture session to `closed` without approvals and observe validation
   reject it.
5. Supply all fixture-only product-owner and integration prerequisites and
   observe validation accept closure.

Expected result: the product owner can see the exact artifacts and understand
that tests, agent approval, integration, and release do not implicitly accept or
close a session. Known limitation: this session does not migrate legacy design
or knowledge and does not change product runtime behavior.

After validation, explicitly ask whether the product owner observed this result
and separately whether it satisfies the specification. Record both in
`REVIEW.md`.

## Acceptance evidence

- Bash syntax and executable modes.
- Typed creation with exact prompt capture.
- Per-specification template checks.
- State-gate rejection and fixture-only accepted closure.
- Immutable worktree registration ancestry and wrong-base rejection.
- Version/changelog/release preview and explicit fixture promotion.
- Documentation links, ignore boundaries, and clean diff checks.
- Product-owner observation, specification acceptance, exact change review,
  integration evidence, and explicit closure remain required separately.
