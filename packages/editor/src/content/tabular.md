# tabular structural edits (tabular.ts)

Pure functions that give a LaTeX `tabular` source a **cell/row grid with source
offsets**, plus immutable edits on that source. This is the model half of shallow
(cell/row) table editing on the canvas — the source-truth answer to "latexml is
one-way".

## Why re-parse the source instead of the compiled HTML

latexml compiles `tabular` -> HTML in one direction, so a cell edit made on the
compiled `<table>` has nowhere to go. Instead we re-parse the SAME source into a grid
whose cells carry `[start, end)` spans. latexml renders rule macros (`\toprule`,
`\midrule`, `\hline`, …) as borders — never as `<tr>`s — so a non-spanned table's
compiled data rows line up 1:1 with these source rows. The canvas affordance zips the
rendered `<td>`s onto this grid by position, resolves a click to a source span, and
splices the source. latexml then re-compiles the edited source: the round-trip is
source-truth, never HTML-truth.

## `parseTabular(source) -> TabularGrid | null`

- `rows` — data rows only. Rule-only / blank chunks are skipped, so `rows[r]` matches
  the r-th rendered data row.
- `rows[r].cells[c]` — `{ text, start, end }` where `source.slice(start, end) === text`
  (trimmed of surrounding whitespace, so a splice keeps the source's padding).
- `columns` — the widest data row; `colspec` — the raw text between the `{}` (a leading
  optional `[pos]` arg and `p{…}` specs are handled).
- `spanned` — true when `\multicolumn`/`\multirow` appears. The compiled grid then no
  longer aligns 1:1 with the source, so the affordance must fall back to raw-source
  (deep) editing rather than mis-map a cell.
- Returns `null` when the string is not a well-formed `tabular`.

Top-level `&` and `\\` are found at brace-depth 0; `\&`, `\%`, and `\{`/`\}` escapes and
`{…}`-guarded content never split a cell or row.

## Edits (`source -> source`)

- `setTabularCell(source, row, col, text)` — replace one cell's text; no-op out of range.
- `insertTabularRow(source, at)` — insert a `\\`-terminated blank row (one empty cell per
  column) after row `at`; terminates row `at` first if it lacked a trailing `\\`.
- `removeTabularRow(source, at)` — drop a data row; no-op out of range or if it is the
  only data row.

## `setDeferredSource(content, tableIndex, source) -> NodeContent`

Replace the `tableIndex`-th `deferred` table run (pre-order — the order `renderContent`
emits `[data-feature="table"]` elements) with new source, so a DOM index maps here
exactly. Everything else round-trips byte-for-byte. This is what the controller commits
via `editContentModel`; the new source re-compiles through the debounced table cache.
