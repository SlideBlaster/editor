---
status: accepted
updated: 2026-07-26
---

# Release and main promotion

Every advance of `main` is a release. Only the product owner initiates it, and
only as a local fast-forward from a clean `dev` release candidate. Session work
first integrates into `dev`; no session integrates directly into `main`.

## Prepare on dev

1. Set product `VERSION` to `X.Y.Z`.
2. Set all 19 Cabal versions to `X.Y.Z.0`.
3. Keep `## [Unreleased]` in `CHANGELOG.md` and add a dated `## [X.Y.Z]` entry.
4. Run applicable build/test gates and record any unavailable gate honestly.
5. Commit the complete release candidate to `dev` through the normal reviewed
   process.

Run non-mutating checks:

```bash
make release-version-check
make release-verify
./scripts/release/promote.sh
```

`release-verify` requires the checked-out clean `dev` tip, exact versions, a
dated changelog entry, local `dev` and `main`, and `main` as an ancestor of
`dev`. If `main` already contains `VERSION`, the candidate version must differ;
the bootstrap promotion is the only case where `main` may not yet have the
file. The promotion command prints the old/new refs by default and changes
nothing.

## Product-owner gate

After reviewing the printed plan, the product owner may explicitly perform the
local fast-forward:

```bash
./scripts/release/promote.sh --execute --confirm X.Y.Z
```

The confirmation must exactly match `VERSION`. The script refuses divergence
and refuses to move `main` while `main` is checked out in a worktree. It neither
switches branches nor pushes. Publishing or pushing remains a separate manual
product-owner action outside this workflow.

The bootstrap preservation point is development commit `4c39b9a`; release
history is recorded in `CHANGELOG.md`, not inferred from session records.
