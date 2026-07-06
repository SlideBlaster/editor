# column grid editor (columnEditor.ts)

The view half of the columns editor (ADR
[0016](../../../../design/decisions/0016-incremental-per-construct-editing.md)) — the
first per-construct (sub-node) affordance on the canvas.

`paintColumnEditors(overlay, slideEl, contentEl, name, content, actions)` decorates
every **top-level** `columns` group in the selected node's rendered content with:

- a **dashed bound** (`.sb-col-bound`) per column,
- a **divider grip** (`.sb-col-divider`) between each neighbour pair,
- an **add-column "+"** (`.sb-col-add`) at the row's end.

## Geometry is DOM-measured

The engine sizes node _boxes_ but never lays out _inside_ a node, so column rects come
from `getBoundingClientRect`, mapped to slide-space percentages of `slideEl` (the same
mapping the node handles use). A `relayout()` closure re-places every element from
current rects; it runs on mount and on every drag frame.

## Interaction (ADR 0016 delta model)

- **Divider drag** previews with pure CSS — it sets the two neighbours' `flex-grow`
  live (their combined width is fixed, so only the internal boundary moves) and never
  commits mid-drag. On `pointerup` it fires **one** `setColumnWidths` transform with the
  rounded pair widths (kept summing to the pair total), via `actions.editContentModel`.
- **"+"** fires one `insertColumn` (an empty column, width = the rounded average of the
  current columns) appended at the end.
- Grips `stopPropagation` on pointer-down so the node handle underneath never starts a
  node drag; the dashed bounds are inert (`pointer-events: none`).

Both gestures commit through the controller's **node-scoped** path
([createApp.md](./createApp.md)): the source is spliced by `minimalDiff`
([sourceDelta.md](./sourceDelta.md)) and only that frame's card + thumbnail repaint.

## Scope

- **Top-level groups only.** Nested `columns` (a group inside a cell) are not decorated
  — kept deliberately simple (ADR 0016). `groupIndex` is still the document (pre-order)
  index, matching `setColumnWidths`/`insertColumn`.
- **Numeric widths.** A drag writes concrete numeric widths; a non-numeric source width
  (`0.5\textwidth`, which already renders as `flex:1`) becomes numeric once dragged.
- **Columns only.** `matrix` shares the intent (a 1-D vs 2-D grid) but its adapter —
  and matrix column resize — is deferred (ADR 0016); a `GridView` seam is extracted when
  that second implementor lands.
