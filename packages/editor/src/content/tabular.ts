/**
 * Structural view of a LaTeX `tabular` source, with source offsets, plus pure edits
 * over that source. Contract: see tabular.md.
 *
 * latexml compiles a `tabular` to HTML ONE-WAY, so shallow (cell/row) editing cannot
 * be read back from the compiled output. Instead we re-parse the SAME source into a
 * cell grid whose cells carry their `[start, end)` span AND their physical grid
 * position `(x, y)`. A LaTeXML preload binding stamps every compiled cell with that
 * same `(x, y)` as `data-sbx`/`data-sby` (see the engine annotation binding), so the
 * canvas affordance resolves a clicked `<td>` to a source cell by grid position —
 * exact even for `\multicolumn`/`\multirow`, and never by trusting the HTML structure.
 * The edit stays in the source (the `deferred` run), which latexml then re-compiles:
 * the round-trip is source-truth, never HTML-truth.
 *
 * Rule-only chunks (`\toprule`, `\midrule`, `\hline`, `\bottomrule`, …) are NOT data
 * rows and are skipped, matching latexml. `spanned` still reports whether
 * `\multicolumn`/`\multirow` is present, but shallow editing no longer bails on it:
 * each cell resolves by its physical `(x, y)`, and a merged cell edits just its wrapped
 * content argument (so `\multicolumn{2}{c}{Half}` rewrites only `Half`).
 */
import type { NodeContent, TextRun } from '../model/content'

/** A trimmed run of source: its text and the `[start, end)` span it occupies. */
export interface TabularContent {
  text: string
  /** Offset of the first non-space char in the source (inclusive). */
  start: number
  /** Offset just past the last non-space char (exclusive). */
  end: number
}

/** A single cell: the full trimmed cell source, its span, its physical grid position,
 *  and the editable inner content (which narrows to the wrapped argument of a spanned
 *  cell). */
export interface TabularCell extends TabularContent {
  /** Physical grid column of the cell's left edge — matches the compiled `data-sbx`. */
  x: number
  /** Columns this cell spans (`\multicolumn{n}` ⇒ n, otherwise 1). */
  colspan: number
  /** The editable inner content: the whole cell, or the wrapped argument of a
   *  `\multicolumn`/`\multirow`, so setting the cell rewrites only the visible text. */
  content: TabularContent
}

/** A data row (rule-only chunks excluded). */
export interface TabularRow {
  cells: TabularCell[]
  /** Offset a following row inserts at — just past this row's `\\`, or its end if none. */
  end: number
  /** Whether the row is terminated by `\\` in the source. */
  terminated: boolean
}

/** The structural grid of a `tabular`, addressable by (row, col) with source spans. */
export interface TabularGrid {
  /** Raw column spec between the braces, e.g. `lr` or `|l|r|`. */
  colspec: string
  /** Physical column count — the widest data row, counting colspans. */
  columns: number
  rows: TabularRow[]
  /** Whether `\multicolumn`/`\multirow` is present (informational; see module doc). */
  spanned: boolean
}

/** Rule/spacing macros that separate rows but are not themselves data. */
const RULE_MACRO = /^\\(?:hline|toprule|midrule|bottomrule|addlinespace|cmidrule|cline|noalign)\b/

/** Parse a `tabular` source into its grid, or null if it is not a well-formed tabular. */
export function parseTabular(source: string): TabularGrid | null {
  const begin = /\\begin\{tabular\}[ \t]*(?:\[[^\]]*\][ \t]*)?\{/.exec(source)
  if (!begin) return null
  const specOpen = begin.index + begin[0].length - 1 // the `{` of the colspec
  const specEnd = matchBrace(source, specOpen)
  if (specEnd === -1) return null
  const colspec = source.slice(specOpen + 1, specEnd)

  const endTok = source.lastIndexOf('\\end{tabular}')
  if (endTok === -1 || endTok < specEnd) return null

  const bodyStart = specEnd + 1
  const rows: TabularRow[] = []
  let columns = 0
  let spanned = false

  for (const chunk of splitRows(source, bodyStart, endTok)) {
    if (/\\multicolumn\b|\\multirow\b/.test(source.slice(chunk.start, chunk.end))) spanned = true
    const cellStart = skipRules(source, chunk.start, chunk.end)
    if (cellStart >= chunk.end) continue // rule-only / blank chunk: not a data row
    const cells = annotateColumns(source, splitCells(source, cellStart, chunk.end))
    const width = cells.reduce((w, c) => w + c.colspan, 0)
    columns = Math.max(columns, width)
    rows.push({ cells, end: chunk.termEnd, terminated: chunk.terminated })
  }

  if (rows.length === 0) return null
  return { colspec, columns, rows, spanned }
}

/** Every `deferred` table run's source in pre-order — the order the renderer emits
 *  `[data-feature="table"]`, so `sources[i]` is the source of the i-th rendered table. */
export function deferredTableSources(content: NodeContent): string[] {
  const out: string[] = []
  if (content.kind !== 'text') return out
  const walk = (runs: readonly TextRun[]): void => {
    for (const run of runs) {
      if (run.kind === 'deferred') {
        if (run.feature === 'table') out.push(run.source)
      } else if (
        run.kind === 'latex' ||
        run.kind === 'markdown' ||
        run.kind === 'html' ||
        run.kind === 'overlay'
      ) {
        walk(run.children)
      } else if (run.kind === 'list') {
        for (const item of run.items) walk(item.children)
      } else if (run.kind === 'columns') {
        for (const col of run.columns) walk(col.children)
      } else if (run.kind === 'matrix') {
        for (const row of run.rows) for (const cell of row) walk(cell.children)
      }
    }
  }
  walk(content.runs)
  return out
}

/** Replace cell (row, col)'s editable content in `source`; a no-op if out of range. For a
 *  spanned cell only the wrapped argument changes, so `\multicolumn`/`\multirow` survives. */
export function setTabularCell(source: string, row: number, col: number, text: string): string {
  const grid = parseTabular(source)
  const cell = grid?.rows[row]?.cells[col]
  if (!cell) return source
  return source.slice(0, cell.content.start) + text + source.slice(cell.content.end)
}

/** Resolve a compiled cell's physical grid position — its `data-sbx`/`data-sby` — to the
 *  source (row, col) indices, or null if no source cell begins at that position (e.g. a
 *  slot covered by a `\multirow` overhang, which the render skips). */
export function resolveTabularCell(
  grid: TabularGrid,
  x: number,
  y: number,
): { row: number; col: number } | null {
  const row = grid.rows[y]
  if (!row) return null
  const col = row.cells.findIndex((c) => c.x === x)
  return col === -1 ? null : { row: y, col }
}

/**
 * A new cell's placeholder. latexml DROPS a fully-empty tabular row (and `~`, `\strut`,
 * `\phantom`, `{}` all still count as empty), so a blank row would compile to nothing —
 * invisible and unfillable. `\mbox{}` is the lightest content latexml keeps: it renders
 * an empty-looking cell but preserves the row (and its coordinates). The editor shows a
 * placeholder cell as empty, and the first real edit replaces the whole `\mbox{}`.
 */
export const EMPTY_CELL = '\\mbox{}'

/**
 * Insert a blank data row after row `at` (clamped). The new row has one placeholder cell
 * per column (see `EMPTY_CELL`) and is `\\`-terminated; if row `at` was not terminated (a
 * last row without a trailing `\\`) it is terminated first so the table stays well-formed.
 */
export function insertTabularRow(source: string, at: number): string {
  const grid = parseTabular(source)
  if (!grid) return source
  const i = Math.max(0, Math.min(at, grid.rows.length - 1))
  const row = grid.rows[i]!
  const blank = Array.from({ length: Math.max(1, grid.columns) }, () => EMPTY_CELL).join(' & ')
  const prefix = row.terminated ? '' : ' \\\\'
  const insert = `${prefix}\n${blank} \\\\`
  return source.slice(0, row.end) + insert + source.slice(row.end)
}

/**
 * Append a column at the right edge: widen the colspec by one `l` and add a placeholder
 * cell to the end of every data row. Appending keeps the edit span-safe (a `\multicolumn`
 * row simply gains one trailing physical column too). No-op on a malformed tabular.
 */
export function insertTabularColumn(source: string): string {
  const grid = parseTabular(source)
  if (!grid) return source
  const begin = /\\begin\{tabular\}[ \t]*(?:\[[^\]]*\][ \t]*)?\{/.exec(source)
  if (!begin) return source
  const specOpen = begin.index + begin[0].length - 1
  const specEnd = matchBrace(source, specOpen)
  if (specEnd === -1) return source

  // Widen the colspec, then append a cell to each row. Apply high offset -> low so each
  // splice leaves the earlier offsets valid.
  const edits: { pos: number; text: string }[] = [{ pos: specEnd, text: 'l' }]
  for (const row of grid.rows) {
    const last = row.cells[row.cells.length - 1]
    if (last) edits.push({ pos: last.end, text: ` & ${EMPTY_CELL}` })
  }
  edits.sort((a, b) => b.pos - a.pos)
  let out = source
  for (const e of edits) out = out.slice(0, e.pos) + e.text + out.slice(e.pos)
  return out
}

/** Remove data row `at`; no-op if out of range or it is the only data row. */
export function removeTabularRow(source: string, at: number): string {
  const grid = parseTabular(source)
  if (!grid || at < 0 || at >= grid.rows.length || grid.rows.length <= 1) return source
  const row = grid.rows[at]!
  // Delete from the previous row's end (or the first cell of this row) through this
  // row's terminator, so the row and its own `\\` go but neighbours are untouched.
  const start = at === 0 ? row.cells[0]!.start : grid.rows[at - 1]!.end
  return source.slice(0, start) + source.slice(row.end)
}

/**
 * Replace the source of the `tableIndex`-th deferred table run (pre-order) in `content`.
 * Pre-order matches the order the renderer emits `[data-feature="table"]` elements, so a
 * DOM index maps here exactly. Everything else round-trips byte-for-byte.
 */
export function setDeferredSource(
  content: NodeContent,
  tableIndex: number,
  source: string,
): NodeContent {
  if (content.kind !== 'text') return content
  let seen = -1
  const mapRuns = (runs: readonly TextRun[]): TextRun[] => runs.map(mapRun)
  const mapRun = (run: TextRun): TextRun => {
    switch (run.kind) {
      case 'deferred':
        if (run.feature === 'table' && ++seen === tableIndex) return { ...run, source }
        return run
      case 'latex':
      case 'markdown':
      case 'html':
      case 'overlay':
        return { ...run, children: mapRuns(run.children) }
      case 'list':
        return {
          ...run,
          items: run.items.map((item) => ({ ...item, children: mapRuns(item.children) })),
        }
      case 'columns':
        return {
          ...run,
          columns: run.columns.map((col) => ({ ...col, children: mapRuns(col.children) })),
        }
      case 'matrix':
        return {
          ...run,
          rows: run.rows.map((row) => row.map((cell) => ({ children: mapRuns(cell.children) }))),
        }
      default:
        return run
    }
  }
  return { ...content, runs: mapRuns(content.runs) }
}

/** A raw row chunk from the tabular body — cell region plus its `\\` terminator span. */
interface RowChunk {
  start: number
  end: number
  termEnd: number
  terminated: boolean
}

/** Split `[from, to)` of `source` into row chunks at top-level (brace-depth-0) `\\`. */
function splitRows(source: string, from: number, to: number): RowChunk[] {
  const chunks: RowChunk[] = []
  let depth = 0
  let start = from
  let i = from
  while (i < to) {
    const ch = source[i]!
    if (ch === '\\') {
      if (source[i + 1] === '\\' && depth === 0) {
        chunks.push({ start, end: i, termEnd: i + 2, terminated: true })
        i += 2
        start = i
        continue
      }
      i += 2 // an escaped char (\{, \&, \%) or a macro's backslash — skip both
      continue
    }
    if (ch === '{') depth++
    else if (ch === '}') depth = Math.max(0, depth - 1)
    i++
  }
  if (start < to) chunks.push({ start, end: to, termEnd: to, terminated: false })
  return chunks
}

/** Skip leading whitespace and rule macros (with any (), [], {} args) from `i`. */
function skipRules(source: string, i: number, to: number): number {
  for (;;) {
    while (i < to && isSpace(source[i]!)) i++
    const m = RULE_MACRO.exec(source.slice(i, to))
    if (!m) return i
    i += m[0].length
    for (;;) {
      const ch = source[i]
      if (ch === '(') i = skipBalanced(source, i, '(', ')', to)
      else if (ch === '[') i = skipBalanced(source, i, '[', ']', to)
      else if (ch === '{') i = skipBalanced(source, i, '{', '}', to)
      else break
    }
  }
}

/** Split `[from, to)` into cells at top-level `&`, each trimmed to its content span. */
function splitCells(source: string, from: number, to: number): TabularContent[] {
  const cells: TabularContent[] = []
  let depth = 0
  let cellStart = from
  let i = from
  while (i < to) {
    const ch = source[i]!
    if (ch === '\\') {
      i += 2 // escaped `\&`, `\%`, or a macro — never a separator
      continue
    }
    if (ch === '{') depth++
    else if (ch === '}') depth = Math.max(0, depth - 1)
    else if (ch === '&' && depth === 0) {
      cells.push(trimSpan(source, cellStart, i))
      cellStart = i + 1
    }
    i++
  }
  cells.push(trimSpan(source, cellStart, to))
  return cells
}

/** Assign each raw cell its physical column `x` (colspans accumulate), its `colspan`,
 *  and its editable inner `content`. Left-to-right, so `x` is the running column sum —
 *  which matches the compiled `data-sbx` a rowspan overhang shifts on the render side. */
function annotateColumns(source: string, raw: TabularContent[]): TabularCell[] {
  const cells: TabularCell[] = []
  let x = 0
  for (const cell of raw) {
    const { colspan, content } = analyzeCell(source, cell)
    cells.push({ ...cell, x, colspan, content })
    x += colspan
  }
  return cells
}

/** Detect a `\multicolumn{n}{spec}{content}` / `\multirow{n}{width}{content}` wrapper,
 *  returning its column span and the inner (visible) content span. A plain cell spans one
 *  column and is its own content. Unrecognized forms edit the whole cell, span one. */
function analyzeCell(
  source: string,
  cell: TabularContent,
): {
  colspan: number
  content: TabularContent
} {
  const macro = /^\\(multicolumn|multirow)(?![a-zA-Z])/.exec(cell.text)
  if (!macro) return { colspan: 1, content: cell }
  const args = readBraceArgs(source, cell.start + macro[0].length, cell.end)
  const content = args[args.length - 1]
  if (args.length < 3 || !content) return { colspan: 1, content: cell }
  let colspan = 1
  if (macro[1] === 'multicolumn') {
    const n = Number.parseInt(args[0]!.text, 10)
    if (Number.isFinite(n) && n > 0) colspan = n
  }
  return { colspan, content }
}

/** Read consecutive `{…}` argument groups (skipping spaces and optional `[…]`) from `p`. */
function readBraceArgs(source: string, p: number, to: number): TabularContent[] {
  const args: TabularContent[] = []
  let i = p
  for (;;) {
    while (i < to && isSpace(source[i]!)) i++
    if (source[i] === '[') {
      i = skipBalanced(source, i, '[', ']', to)
      continue
    }
    if (source[i] !== '{') break
    const close = matchBrace(source, i)
    if (close === -1 || close >= to) break
    args.push(trimSpan(source, i + 1, close))
    i = close + 1
  }
  return args
}

/** The trimmed content span of `[a, b)`. */
function trimSpan(source: string, a: number, b: number): TabularContent {
  let start = a
  let end = b
  while (start < end && isSpace(source[start]!)) start++
  while (end > start && isSpace(source[end - 1]!)) end--
  return { text: source.slice(start, end), start, end }
}

/** Index just past the balancing close for an `open` at `i`, or `to` if unbalanced. */
function skipBalanced(source: string, i: number, open: string, close: string, to: number): number {
  let depth = 0
  while (i < to) {
    const ch = source[i]!
    if (ch === '\\') {
      i += 2
      continue
    }
    if (ch === open) depth++
    else if (ch === close && --depth === 0) return i + 1
    i++
  }
  return to
}

/** Index of the `}` balancing the `{` at `open`, or -1 if unbalanced. */
function matchBrace(source: string, open: number): number {
  let depth = 0
  for (let i = open; i < source.length; i++) {
    const ch = source[i]!
    if (ch === '\\') {
      i++
      continue
    }
    if (ch === '{') depth++
    else if (ch === '}' && --depth === 0) return i
  }
  return -1
}

function isSpace(ch: string): boolean {
  return ch === ' ' || ch === '\t' || ch === '\n' || ch === '\r'
}
