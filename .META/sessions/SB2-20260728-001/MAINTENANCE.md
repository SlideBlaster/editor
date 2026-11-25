# SB2-20260728-001 maintenance plan

## Current condition

`FEATURES.md` contains the broad product inventory, but there is no root roadmap that orders feature delivery or separates implementation, local verification, product-owner observation, product-owner acceptance, and release readiness.

There is also no reusable prompt that constrains an implementation swarm to one priority-ready local slice and prohibits publication.

## Intended change

Add a root `ROADMAP.md` with a dependency-ordered release-candidate queue, feature-area coverage ledger, witness record, local readiness gate, and prose-only publication plan, then capture a reusable bounded-swarm prompt in this session’s `.prompt`.

No implementation specification, product source, test, manifest, version, changelog, or release configuration is changed.

## Observable artifact and outcome

The product owner can inspect `ROADMAP.md` to see what should be built first, what each status means, which existing session owns P0, and how explicit witness and acceptance are recorded.

The product owner can inspect `.META/sessions/SB2-20260728-001/.prompt` to see the exact local-only one-slice swarm instructions and publication prohibitions.

## Safety and rollback

All changes are additive local Markdown files, no command may contact a remote or publish an artifact, and rollback consists of deleting only `ROADMAP.md` and `.META/sessions/SB2-20260728-001/` after explicit product-owner instruction.

The existing untracked `.kiro/` and `FEATURES.md` are preserved untouched by this session.

## Validation

- `make metadata-validate` passed, including the new maintenance session and existing metadata.
- `./scripts/session/validate.sh SB2-20260728-001` passed.
- A focused local safeguard check confirmed all required maintenance files are non-empty, `SPEC.md`, `SLICES.md`, and `RESEARCH.md` are absent, Markdown has no trailing whitespace, P0 through P15 are present, the witness statuses are present, and the prompt prohibits publication operations.
- `git status --short` confirmed that the new roadmap and session remain untracked and that pre-existing `.kiro/` and `FEATURES.md` remain untracked.

Content validation does not register the session, make it worktree-eligible, imply product-owner acceptance, or authorize integration or publication.
