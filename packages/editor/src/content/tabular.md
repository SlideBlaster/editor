# tabular structural edits (tabular.ts)

Pure functions that give a LaTeX `tabular` source a **cell/row grid with source
offsets**, plus immutable edits on that source. This is the model half of shallow
(cell/row) table editing on the canvas — the source-truth answer to "latexml is
one-way".

## Why re-parse the source instead of the compiled HTML

latexml compiles `tabular` -> HTML in one direction, so a cell edit made on the
compiled `<table>` has nowhere to go. Instead we re-parse the SAME source into a grid
whose cells carry `[start, end)` spans AND their physical grid position `(x, y)`. The
annotation binding (adapters-shared `tableAnnotation.ts`) stamps every compiled cell
with that same `(x, y)` as `data-sbx`/`data-sby`, so the canvas affordance reads a
clicked `<td>`'s coordinate and `resolveTabularCell` maps it to a source cell — exact
even across `\multicolumn`/`\multirow`, never trusting the HTML structure. latexml then
re-compiles the edited source: the round-trip is source-truth, never HTML-truth.

## `parseTabular(source) -> TabularGrid | null`

- `rows` — data rows only. Rule-only / blank chunks (`\toprule`, `\hline`, …) are
  skipped, matching latexml (which renders them as borders, not `<tr>`s), so `rows[y]`
  matches the y-th rendered data row.
- `rows[r].cells[c]` — `{ text, start, end, x, colspan, content }`. `text`/`start`/`end`
  are the full trimmed cell (`source.slice(start, end) === text`); `x` is the physical
  column of the cell's left edge (matches `data-sbx`); `colspan` is the column span
  (`\multicolumn{n}` ⇒ n); `content` is the editable inner span — the whole cell, or the
  wrapped argument of a `\multicolumn`/`\multirow` so a merged cell edits just its text.
- `columns` — the widest data row counting colspans; `colspec` — the raw text between the
  `{}` (a leading optional `[pos]` arg and `p{…}` specs are handled).
- `spanned` — whether `\multicolumn`/`\multirow` appears (informational; editing resolves
  per cell by `(x, y)` and no longer bails on spanned tables).
- Returns `null` when the string is not a well-formed `tabular`.

Top-level `&` and `\\` are found at brace-depth 0; `\&`, `\%`, and `\{`/`\}` escapes and
`{…}`-guarded content never split a cell or row.

## `resolveTabularCell(grid, x, y) -> { row, col } | null`

Map a compiled cell's physical position — its `data-sbx`/`data-sby` — to source
`(row, col)` indices, or `null` when no source cell begins there (e.g. a slot a
`\multirow` overhang covers, which the render skips). Source `x` is the running colspan
sum and `y` the data-row index, mirroring the binding's occupancy walk.

## Edits (`source -> source`)

- `setTabularCell(source, row, col, text)` — replace one cell's editable content (only the
  wrapped argument for a `\multicolumn`/`\multirow`); no-op out of range.
- `insertTabularRow(source, at)` — insert a `\\`-terminated row after row `at`, each cell
  seeded with `EMPTY_CELL` (`\mbox{}`); terminates row `at` first if it lacked a trailing
  `\\`. The placeholder matters: latexml **drops a fully-empty row** (as it does `~`,
  `\strut`, `\phantom`, `{}`), so a truly blank row would compile to nothing — invisible
  and unfillable. `\mbox{}` is the lightest content latexml keeps; the editor shows it as
  empty and the first real edit replaces the whole `\mbox{}`.
- `insertTabularColumn(source)` — append a column at the right edge: widen the colspec by
  one `l` and add an `EMPTY_CELL` to every data row. Appending is span-safe.
- `removeTabularRow(source, at)` — drop a data row; no-op out of range or if it is the
  only data row.

## `setDeferredSource(content, tableIndex, source) -> NodeContent`

Replace the `tableIndex`-th `deferred` table run (pre-order — the order `renderContent`
emits `[data-feature="table"]` elements) with new source, so a DOM index maps here
exactly. Everything else round-trips byte-for-byte. This is what the controller commits
via `editContentModel`; the new source re-compiles through the debounced table cache.
