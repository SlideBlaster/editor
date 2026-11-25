# SB2-20260726-001: Development workflow scaffolding

- ID: `SB2-20260726-001`
- Type: `implementation`
- Status: `closed`
- Created: `2026-07-26`
- Base branch: `dev`
- Session branch: `session/SB2-20260726-001`

## Goal

Install the accepted `.META` design/knowledge destinations, prompt capture,
typed sessions, per-specification demonstration, steering, review, state,
worktree, research, version, changelog, and product-owner release rails without
changing product semantics.

## Ownership

This session owns `.META/` scaffolding, workflow scripts, workflow runbooks and
ADR 0006, release metadata, and links from repository governance and indexes.
Product Haskell, browser behavior, external reference checkouts, and legacy
`../design/` and `../knowledge/` content are read-only.

## Evidence

- Preservation commit: `4c39b9a stash`.
- `dev` was created at that preservation commit.
- The 578 MB unpinned `.META/sources/drawio/` checkout remains ignored.
- Exact repository-local and isolated workflow checks are captured in the
  session's research artifact.

## Handoff

The previous scaffold passed independent review, after which the product owner
requested `.META` design/knowledge authority, prompt capture, per-specification
user demonstrations, durable steering, exact change review, and explicit
closure states. Those revisions now pass repository-local checks, adversarial
isolated fixtures, and final independent read-only audit.

The product owner observed and accepted the specified workflow, approved the
exact 50-file review patch, and explicitly authorized integration commit
`76db98305b7dcf56a15878572fb149b85fc5a35d` on `dev`. Post-integration checks
passed, and the product owner explicitly approved closing this session on
2026-07-27.

The session is closed. `main` remains at preservation commit `4c39b9a` and can
advance only through a separate product-owner release action.
