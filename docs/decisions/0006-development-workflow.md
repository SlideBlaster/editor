---
status: accepted
updated: 2026-07-27
---

# 0006. Repository control plane, development sessions, and releases

## Context

SlideBlaster 2 needs durable product intent, semantic memory, session evidence,
and safe Git operations. Technical verification alone cannot establish that the
product owner saw an artifact, accepted its behaviour, reviewed its exact
changes, or approved closure. The old implementation must remain a behavioural
and fixture oracle while legacy design and knowledge are migrated safely.

## Decision

`.META` is the repository control plane:

- `.META/design/` is the destination authority for product, format, UX, service,
  and cross-cutting design;
- `.META/knowledge/` is the destination authority for concise accepted semantic
  memory;
- `.META/sessions/` records initiating prompts, specifications or type-specific
  plans, slices, steering, evidence, review, integration, and closure;
- `.META/research/` records reproducible evidence that is not automatically an
  accepted decision;
- `.META/sources/` tracks provenance manifests while local third-party checkouts
  remain ignored.

The existing `../design/` and `../knowledge/` trees are not migrated by this
session. A later dedicated session must inventory and transfer them, update
links, leave migration notices, validate knowledge indexing, and obtain separate
approval before deleting old copies. Until then agents search both locations
and preserve the legacy files.

Session IDs are `SB2-YYYYMMDD-NNN`. Every session contains a non-empty `.prompt`
with the initiating agent prompt, plus `SESSION.md`, `STEERING.md`, and
`REVIEW.md`. Type-specific records are:

- implementation: `SPEC.md` and `SLICES.md`;
- research: `RESEARCH.md`;
- maintenance: `MAINTENANCE.md`.

For implementation, the complete artifact inventory, observable functionality,
product-owner demonstration, and acceptance contract belong once in `SPEC.md`,
not once per slice. Slices remain technical implementation and verification
increments. Research and maintenance record an appropriate observable outcome.

The agent explicitly asks whether the product owner can observe the artifact and
separately whether it satisfies the intended specification or outcome. Silence
is not acceptance. Material steering is recorded and resolved; deferral is
resolved only when the product owner agrees.

Session states are:

```text
active | blocked | ready-for-demonstration | changes-requested
  -> ready-for-review
  -> approved-for-integration
  -> integrated-awaiting-close
  -> closed
```

Rejection or requested changes keep the session open. `ready-for-review`
requires recorded observation, outcome acceptance, and resolved steering.
Approval for integration additionally requires product-owner review of an exact
PR, merge request, commit range, patch, or local diff. Integration records a
full commit contained in `dev`. Only an explicit product-owner closure response
permits `closed`; tests, agent review, merging, or release do not imply closure.

Normal session branches are `session/<ID>` from local `dev`, and worktrees may
be outside the repository. The branch must contain the immutable commit that
first registered its session record on `dev`. Completed sessions integrate only
into `dev`.

Operational research runs use
`.META/research/<session-id>--<task-slug>--<agent-slug>--<run>/`.

`VERSION` is the product version. Product `X.Y.Z` maps to Cabal `X.Y.Z.0` in all
16 packages. `CHANGELOG.md` keeps `Unreleased` and a dated entry for every
released version.

`main` advances only through a product-owner-initiated local fast-forward from a
clean, versioned, changelog-backed `dev` candidate. Every advance of `main` is a
release. Workflow tooling never pushes.

The implementation in `../editor/` remains the behavioural and fixture oracle
until a separate accepted decision retires it.

## Consequences

The workflow remains dependency-free Bash and Markdown. It adds no hosted
service, CI-provider configuration, automatic push, or automatic release or
closure authority. Mutating worktree creation and release promotion require
explicit confirmation. Divergent `main` and `dev` require deliberate
reconciliation, never force.

Prompt capture must not be used to commit credentials or secrets; the owning
agent must review `.prompt` before registration. The pre-existing bootstrap
session records that its exact initiating prompt predates this rule rather than
fabricating one.
