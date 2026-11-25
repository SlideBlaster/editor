# SB2-20260729-001 maintenance plan

## Current condition

The product owner has prioritized core TikZ authoring breadth ahead of project persistence and cosmetic product work, but no reusable bounded-swarm prompt currently captures that exact slice and its source-preservation gates.

The active P0 worktree contains substantial overlapping TikZ, application, protocol, runtime, and browser work, so future execution must wait for explicit ownership release rather than beginning a competing mutation.

## Intended change

Capture one future-swarm prompt that defines the requested core TikZ breadth, required independent roles, source and architecture laws, realistic fixture requirement, local verification ladder, product-owner witness gates, and strict prohibition on publication.

Create only the required maintenance-session records around that prompt.

## Observable artifact and outcome

The product owner can inspect `.META/sessions/SB2-20260729-001/.prompt` and confirm that it covers multiple nodes, real content, styling and placement, connectors, supported canvas operations, exact verified source edits, unsupported read-only preservation, and a meaningful fixture.

The prompt must be directly reusable to launch a future governed agent swarm after overlapping P0 ownership is released.

## Safety and rollback

All scaffold changes are additive Markdown files under one new session directory.

No product source, test, roadmap, feature inventory, existing session, Git branch, commit, worktree, remote, or release state is changed.

Rollback, only if explicitly requested, consists of removing `.META/sessions/SB2-20260729-001/` and nothing else.

## Validation

- `make metadata-validate` passed, including this new active maintenance session and all existing metadata.
- `./scripts/session/validate.sh SB2-20260729-001` passed.
- Required-file and Markdown-hygiene checks passed.
- All sixteen focused prompt checks passed, covering the eleven requested TikZ capabilities, P0 ownership release, local-only execution, publication prohibition, and separate observation and acceptance questions.
- `SPEC.md`, `SLICES.md`, and `RESEARCH.md` are absent, and no implementation files were created.
- Final `git status --short` shows only this new untracked scaffold plus the same pre-existing untracked session, `.kiro/`, `FEATURES.md`, and `ROADMAP.md`.

Content validation does not register the session, make it worktree-eligible, imply product-owner acceptance, or authorize implementation, integration, or publication.
