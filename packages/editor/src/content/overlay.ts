/**
 * Interpret a Beamer overlay spec. Contract: see overlay.md.
 *
 * A spec is the raw text inside `<…>` — a comma-separated union of terms, each a
 * single step (`3`), an open-from range (`2-`), an open-to range (`-3`), or a closed
 * range (`2-4`). Steps are 1-based positive integers. The model stores the raw text
 * (round-trip truth); everything here is a pure function of it, nothing cached.
 */
import type { NodeContent, OverlaySpec, TextRun } from '../model/content'

/** One parsed interval; `null` bound = open in that direction. */
interface Interval {
  from: number | null
  to: number | null
}

/** A single spec term, e.g. `2`, `2-`, `-3`, `2-4` (whitespace tolerated). */
const TERM = /^\s*(?:(\d+)|(\d+)-|-(\d+)|(\d+)-(\d+))\s*$/

/** Parse a raw spec into intervals, or `null` if any term is malformed/empty. */
function parseIntervals(raw: string): Interval[] | null {
  const terms = raw.split(',')
  if (terms.length === 0) return null
  const intervals: Interval[] = []
  for (const term of terms) {
    const m = TERM.exec(term)
    if (m === null) return null
    if (m[1] !== undefined) intervals.push({ from: Number(m[1]), to: Number(m[1]) })
    else if (m[2] !== undefined) intervals.push({ from: Number(m[2]), to: null })
    else if (m[3] !== undefined) intervals.push({ from: null, to: Number(m[3]) })
    else intervals.push({ from: Number(m[4]), to: Number(m[5]) })
  }
  return intervals
}

/** Whether `raw` is a syntactically valid overlay spec (the parser's subset gate). */
export function isValidSpec(raw: string): boolean {
  const intervals = parseIntervals(raw)
  if (intervals === null) return false
  // A backwards closed range (`4-2`) is malformed.
  return intervals.every((i) => i.from === null || i.to === null || i.from <= i.to)
}

/** Whether the spec includes `step` (1-based). A malformed spec is inactive everywhere. */
export function activeAt(spec: OverlaySpec, step: number): boolean {
  const intervals = parseIntervals(spec.raw)
  if (intervals === null) return false
  return intervals.some(
    (i) => (i.from === null || step >= i.from) && (i.to === null || step <= i.to),
  )
}

/** The largest finite step the spec names (0 if it names none). Drives the slide's step
 *  count: an open range `<2->` contributes its lower bound, extending the count to it. */
export function specMaxStep(spec: OverlaySpec): number {
  const intervals = parseIntervals(spec.raw)
  if (intervals === null) return 0
  let max = 0
  for (const i of intervals) {
    if (i.from !== null) max = Math.max(max, i.from)
    if (i.to !== null) max = Math.max(max, i.to)
  }
  return max
}

/** The smallest step the spec names (1 when it is open at the start). Used to compute the
 *  step floor a `\pause<spec>`/`\appear<spec>` sets for the content that follows. */
export function specMinStep(spec: OverlaySpec): number {
  const intervals = parseIntervals(spec.raw)
  if (intervals === null) return 1
  let min = Infinity
  for (const i of intervals) min = Math.min(min, i.from ?? 1)
  return Number.isFinite(min) ? min : 1
}

/**
 * The highest step a node body references — its inline contribution to the slide step
 * count. Mirrors the renderer's reading-order model: `\pause`/`\appear` raise a per-level
 * floor (content after them lands one step later, or at the spec's min), overlay wrappers
 * and `\item<spec>` contribute their spec's max step, and containers recurse. Always >= 1.
 */
export function contentMaxStep(content: NodeContent): number {
  return content.kind === 'text' ? runsMaxStep(content.runs, 1) : 1
}

function runsMaxStep(runs: TextRun[], floor: number): number {
  let max = floor
  let f = floor
  for (const run of runs) {
    if (run.kind === 'fragment') {
      f = run.spec ? specMinStep(run.spec) : f + 1
      max = Math.max(max, f)
      continue
    }
    max = Math.max(max, runMaxStep(run, f))
  }
  return max
}

function runMaxStep(run: TextRun, floor: number): number {
  switch (run.kind) {
    case 'overlay':
      return Math.max(run.spec ? specMaxStep(run.spec) : floor, runsMaxStep(run.children, floor))
    case 'latex':
    case 'markdown':
    case 'html':
      return runsMaxStep(run.children, floor)
    case 'list':
      return run.items.reduce(
        (m, item) =>
          Math.max(
            m,
            item.spec ? specMaxStep(item.spec) : floor,
            runsMaxStep(item.children, floor),
          ),
        floor,
      )
    case 'columns':
      return run.columns.reduce((m, col) => Math.max(m, runsMaxStep(col.children, floor)), floor)
    case 'matrix':
      return run.rows.reduce(
        (m, row) => row.reduce((mm, cell) => Math.max(mm, runsMaxStep(cell.children, floor)), m),
        floor,
      )
    default:
      return floor
  }
}
