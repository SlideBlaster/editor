# columns transforms (columns.ts)

Pure, immutable edits on `columns` groups inside a node body — the model half of the
canvas grid affordance (ADR
[0016](../../../../design/decisions/0016-incremental-per-construct-editing.md)). A
divider drag or "+" gesture becomes exactly one of these `NodeContent -> NodeContent`
transforms; the controller derives the source and canvas deltas from the result.

## Addressing

Each transform targets the `groupIndex`-th `columns` run in **document (pre-order)
order** — a parent `columns` group is counted before any group nested inside its
cells. This is exactly the order `renderContent` emits `.sb-columns` elements, so the
`data-path` index the overlay reads off the DOM maps straight to `groupIndex` here.
Non-`text` content (`empty` / `error`) returns unchanged.

## Transforms

- `setColumnWidths(content, groupIndex, patch)` — `patch` maps a column index to its
  new raw `\column{…}` width string. Columns absent from the patch keep their source
  width, so a two-neighbour resize never rewrites the others.
- `insertColumn(content, groupIndex, at, width)` — insert an empty column (`children:
[]`) at `at` (clamped to `[0, length]`) with the given width.
- `removeColumn(content, groupIndex, at)` — drop the column at `at`. No-op when out of
  range or when it is the only column (a group keeps at least one).

## Invariant

Everything except the touched columns is preserved — other runs, other groups, every
cell's children and dialect — so `serializeBody` round-trips byte-for-byte outside the
edited widths/columns. Widths are opaque strings; the app formats numeric drag results
(e.g. `0.55`) before calling.
