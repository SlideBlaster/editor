---
status: accepted
updated: 2026-07-23
---

# 0002. Source buffers are authoritative and semantic canvas edits are verified

This is the repository-local implementation record for the snapshot and edit
laws accepted by cross-project
[ADR 0025](../../../design/decisions/0025-slideblaster2-haskell-core.md).

## Decision

The immediate authority is `SourceBufferSnapshot`: exact authored bytes plus an
opaque, monotonic revision. The current Slice 0 engine exposes this value and
mechanically checked exact replacement only.

`DocumentSnapshot format` is reserved for a later source+CST+analysis+
provenance+diagnostics representation locked to one source revision. Its syntax
and semantic fields are derived and may be partial or absent for invalid input;
they never supersede the source buffer.

Direct source authorship and semantic canvas editing are distinct operations.
A direct code-pane replacement becomes the newest source revision even if its
reparse has diagnostics and no current semantic meaning; any older canvas is
then inert. It does not need to prove semantic equivalence because the user's
authored bytes are themselves the intent.

Canvas-derived changes enter as typed `EditIntent` values. A successful semantic
edit:

1. computes the intended semantic change;
2. projects it only through an authorized provenance rule;
3. checks the exact source revision and expected old bytes;
4. applies a local candidate patch;
5. reparses and elaborates the result;
6. verifies semantic equality with the intended result; and
7. only then creates a new source/history snapshot.

The candidate and verified patch phases are private implementation types behind
the public `applyEdit` operation.

## Constraints

- Unrelated source bytes remain identical.
- Failure is atomic.
- Expanded or ambiguous constructs are read-only without an explicit inverse.
- Layout and render plans never become persistence authorities.
- Direct source edits may enter source history and persistence after their
  revision fence even when syntax is temporarily invalid.
- Canvas-derived semantic edits may enter source history and persistence only
  after semantic verification.
- Neither path implicitly canonicalizes the whole document. The product policy
  for an explicit formatter is deferred.

## Consequences

The implementation carries more information than a one-way Pandoc-style AST,
but clients see a smaller API. Exact source preservation and partial inverse
editing become enforceable boundaries rather than controller conventions.
