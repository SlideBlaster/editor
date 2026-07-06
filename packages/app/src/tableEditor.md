# Table shallow-edit affordance (tableEditor.ts)

The view half of shallow (cell/row) table editing — the canvas counterpart to the
engine model in `content/tabular.ts`. Over the **selected** node it decorates every
compiled `deferred` table; the model computes source edits, this paints the grips and
commits them. Mirrors `columnEditor.ts` (ADR 0016 grid affordance).

## `paintTableEditors(overlay, slideEl, contentEl, name, content, actions)`

For each `[data-feature="table"]` wrapper in the selected node's content (indexed to
match `deferredTableSources(content)`), mount an inert `.sb-table-edit` layer carrying:

- **Cell hotspots** (`.sb-table-cell`) — one per rendered cell that carries source
  coordinates. Click opens an inline `<textarea>` over the cell, seeded from the source
  cell's editable content; blur or Enter commits `setTabularCell`, Escape cancels,
  Shift+Enter keeps a newline.
- **Add row / add column** (`.sb-table-add`, "+") — one grip below the table appends a row
  (`insertTabularRow`), one at the right edge appends a column (`insertTabularColumn`). New
  cells are seeded with a `\mbox{}` placeholder so the row/column actually renders (latexml
  drops a truly empty row); the editor shows placeholder cells as empty.
- **Deep edit** (`.sb-table-source`, "</>") — always present; opens the whole `tabular`
  source in a modal textarea (the popup for a small table whose source dwarfs its box).
  Save commits the raw source; Cancel/Escape discards. This is the level-2 escape hatch
  and the only affordance for a table that lacks coordinates.

Every gesture becomes one source-string edit spliced into the `deferred` run via
`setDeferredSource`, committed with `actions.editContentModel(name, ...)`; latexml then
re-compiles. After a commit the new source is a cache miss, so the table shows "render
pending" briefly — during that window only the deep-edit grip shows.

## How a rendered cell resolves to source

latexml is one-way, so a cell carries no source of its own. The annotation binding
(adapters-shared `tableAnnotation.ts`) stamps each compiled `<td>`/`<th>` with its
physical grid position as `data-sbx`/`data-sby`. `resolveCells` reads those (scoped to
the outermost table, so a nested tabular's coordinates never mis-resolve) and maps each
to a source `(row, col)` with `resolveTabularCell`. Identity thus originates in the
source, never in the HTML structure — see [[latexml-source-annotation]]. A table whose
cells lack coordinates (annotation off, or a cache entry compiled before it) gets the
deep editor only.

## Geometry & interaction

Positions are percentages of the slide box, measured from the rendered cells'
`getBoundingClientRect()` after paint (so it runs after the render, like
`columnEditor`). Grips take pointer events and `stopPropagation` on `pointerdown` so a
click edits rather than dragging the node; the node still moves by dragging its border
outside any cell. Mounted both on full paint (`canvas.ts`) and on selection-only
repaint (`deck.ts` `setColumnEditors`).
