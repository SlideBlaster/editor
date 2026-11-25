# Research artifact: legacy-editable-canvas

- Slug: `SB2-20260727-001--legacy-editable-canvas--legacy-analyst--01`
- Session: `SB2-20260727-001`
- Agent: `legacy-analyst`
- Created: `2026-07-27`
- Status: `complete`

## Question

Which observable legacy editable-canvas behaviours are migration oracles for the bounded exact-source node-drag slice, and which implementation details must not be ported?

## Source and provenance

Read-only local legacy checkout adjacent to the governed repository at the session registration revision `cbe29eb4f989f830b17157812e2c8180dbb690e0`. Primary evidence inspected:

- `../editor/packages/app/src/{createApp.ts,createApp.md,canvas.ts,canvas.md,snap.ts,snap.test.ts}`
- `../editor/packages/editor/src/edit/{transaction.ts,transaction.test.ts,ops.ts}`
- `../editor/packages/editor/src/tikz/{sourceEdit.ts,sourceEdit.test.ts,connector.ts,connector.test.ts}`
- `../editor/packages/editor/src/render/slide.ts`
- `../editor/e2e/{browser-requirements.spec.ts,browser-model.spec.ts,generated-locality.spec.ts,appDriver.ts}`
- `../design/ux/positioning-snapping.md`
- `../design/decisions/{0006-positioning-and-snapping.md,0014-layered-dom-render-surface.md,0015-out-of-subset-is-a-hard-error.md,0016-incremental-per-construct-editing.md}`
- `../design/format/{tikz-subset.md,stencil-pipeline.md}`
- `../knowledge/concepts/{edit-commit-source-history.md,verification-and-reduction-worklist.md,bidirectional-tikz-edit-transaction.md,editable-connector-subset.md,out-of-subset-hard-error.md,source-to-dom-validation-boundary.md,browser-working-copy.md,multi-shape-selection.md,layered-dom-render-surface.md,shapes-as-option-presets.md}`

No files were modified.

## Reproduction

Inspect the listed symbols and fixtures read-only from the governed worktree. Compare prose against executable tests; do not treat test presence as passing evidence.

## Observations

### Source and canvas authority

`createApp.ts` maintains exact source plus `sourceRevision`, `canvasSourceRevision`, and canvas source state. A canvas is writable only when it owns the current revision. Every render captures sequence and revision; delayed work cannot claim newer text. Invalid direct source remains exact and repairable while last-good paint stays visible but inert.

`sourceEdit.ts:projectTikzEditTransaction` projects local authored spans, rejects unavailable or conflicting provenance, reparses the candidate, and compares candidate semantics with the intended transaction. Multi-span edits apply in descending offset order. Tests preserve comments, styles, macros, CRLF, Unicode, and untouched frame bytes. The new goal strengthens this with explicit exact expected-byte checks.

### One typed operation for preview and commit

`transaction.ts:applyTikzEditIntent` creates one semantic transaction. `previewTikzEditIntent` and release consume the same intent and ordinary layout. Pointer cancel restores authoritative paint; sub-threshold gestures do not commit; one release creates at most one action.

### Selection, snapping, and movement

Selection replacement/toggle is surface-local. Legacy DOM-class selection is a pointer-capture workaround, not an authority model to port. Absolute snapping resolves each axis with alignment, then equal spacing, then grid; relative binding is attempted before absolute snapping. Alt bypasses binding/snapping and is used by deterministic locality E2E fixtures. Exact constants are reversible UX parameters, not source laws.

### Commit and history

Only a verified byte-changing projection pushes the exact pre-edit source once, clears redo, advances source, and rerenders. Rejection and byte no-op create no source/history change. Undo/redo restore whole exact source snapshots. One multi-node gesture is one undo step. Browser-owned arrays and the stack cap are obsolete implementation details.

### Unsupported syntax

Generated, repeated, ambiguous, derived, or missing-inverse provenance is read-only and rejects atomically. Malformed source remains authoritative. Draft tier prose conflicts with accepted hard-error prose for macros/foreach/calc; this session must classify only its bounded fixture and must not redefine T0/T1/T2 globally.

### Connectors and outlines

Named connectors resolve endpoints from successor layout; moving a node leaves `\draw[->] (a) -- (b);` byte-identical while rendered geometry follows. This is the needed connector oracle; connector editing breadth is excluded. Shapes become ordinary semantic nodes with generic outline geometry after insertion; raw catalog/draw.io implementation is not another scene model.

### Browser boundary

Legacy TypeScript owns too much and must not be copied. Preserve only observable event, pointer-capture, validated paint, and browser-capability behaviour. Parsing, snapping policy, semantic intent, projection, verification, history, leases, and acceptance belong in shared Haskell.

## Oracle versus obsolete detail

| Preserve | Do not port |
| --- | --- |
| exact bytes/revision as authority | monolithic mutable TypeScript controller |
| exact painted-revision edit fence | browser source parser/projector/history |
| same typed preview/commit operation | DOM classes as semantic authority |
| provenance-local expected-byte patches | whole-document serialization fallback |
| candidate reparse + intended semantics | semantic array undo and cap |
| one accepted gesture = one source transaction | raw draw.io/TypeScript registries |
| rejection/no-op atomicity | connector editor breadth |
| unchanged connector source follows moved node | browser-owned acceptance or snapping policy |

## Limitations

`.META/sources/drawio/` is absent. `.META/sources/README.md` says the ignored checkout must not be traversed, modified, or committed without pinned provenance. This conflicts with a broad instruction to inspect it; the analyst obeyed the stronger repository policy. Raw draw.io evidence is not required by this slice. Several legacy browser properties were historically expected-red according to `verification-and-reduction-worklist.md`; their presence is not reported as a pass.

## Conclusion

The bounded migration contract is: open exact noncanonical two-node-plus-connector bytes; issue one revision/gesture/lease-fenced Haskell move; patch only direct coordinate slots after exact expected-byte checks; reparse and verify intended semantics; record one exact-source history transaction; repaint only the accepted successor; undo to byte-exact original. Stale, ambiguous, generated, unsupported, malformed, mismatch, no-op, cancel, and late-response paths leave authority unchanged. This is evidence, not an accepted architectural or product decision.
