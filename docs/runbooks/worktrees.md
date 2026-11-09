---
status: accepted
updated: 2026-07-27
---

# Session worktrees

Normal session branches are named `session/SB2-YYYYMMDD-NNN` and start at the
local `dev` tip. Worktree paths may be siblings of this repository or elsewhere
on local storage; the path is not persisted as an authoritative contract.

Create and validate the complete session record first from a clean `dev`,
including `.prompt`, `STEERING.md`, `REVIEW.md`, and its type-specific files.
Review `.prompt` for secrets, then commit `.META/sessions/<ID>/` to `dev`. The
worktree command refuses an uncommitted registration. Preview with:

```bash
./scripts/session/worktree.sh plan SB2-20260726-001 ../sb2-SB2-20260726-001
```

Creation is the only mutating mode and requires explicit confirmation:

```bash
./scripts/session/worktree.sh create SB2-20260726-001 \
  ../sb2-SB2-20260726-001 --confirm
./scripts/session/worktree.sh validate SB2-20260726-001 \
  ../sb2-SB2-20260726-001
```

The validator checks the session record, exact branch, shared Git repository,
and descent from the immutable `dev` commit that first registered the record.
Later `dev` advances and later record edits do not move that anchor. Worktree
validation does not establish technical correctness, product-owner observation,
acceptance, review, or closure.

Before parallel work, assign one writer per file and inspect status in every
shared worktree. Approved completed work integrates into `dev`, never directly
into `main`. Record the exact review unit and integration commit in `REVIEW.md`,
then request product-owner closure separately. Do not remove a worktree or delete
a branch through these scripts; cleanup is a separate deliberate operator
action under repository safety rules.
