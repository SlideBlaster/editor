/**
 * Pure node style-option writers: the write half of the style panel. Contract: see
 * nodeStyle.md.
 *
 * Each `withX(options, value)` takes a node's raw TikZ option tokens and returns a NEW array
 * with just that one knob rewritten — every unrelated token (the theme role class, placement,
 * size floors, other knobs) is preserved. The panel reads the current tokens (via the
 * engine's `tikz/options` derived views), calls the matching writer, and commits the result
 * through `setNodeOptions`. This mirrors the connector `withDirection`/`withDashed` idiom, so
 * a panel edit and a hand-typed `\node[...]` stay byte-identical (ADR 0004,
 * shapes-as-option-presets).
 *
 * The vocabulary (`LINE_WIDTHS`, `DASH_PATTERNS`, shape names) is imported from the engine so
 * the reader, the renderer, and these writers can never disagree.
 */
import {
  DASH_PATTERNS,
  LINE_WIDTHS,
  type DashPattern,
  type LineWidthName,
  type NodeShape,
} from '@slideblaster/editor'

const DRAW_RE = /^draw(?:\s*=|$)/ // bare `draw` or `draw=<color>`, NOT `draw opacity=`
const FILL_RE = /^fill\s*=/
const LINE_WIDTH_RE = /^line\s+width\s*=/
const OPACITY_RE = /^opacity\s*=/
const FILL_OPACITY_RE = /^fill\s+opacity\s*=/
const DRAW_OPACITY_RE = /^draw\s+opacity\s*=/
const ROUNDED_RE = /^rounded\s+corners\b/
const FONT_SIZE_RE = /^font\s+size\s*=/

const SHAPE_TOKENS = ['rectangle', 'ellipse', 'circle']

/** Set the node's outline: `ellipse` adds the bare token; `rectangle` is the default (no
 *  token). Drops any prior shape token; leaves paint/size untouched. */
export function withShape(options: string[], shape: NodeShape): string[] {
  const rest = options.filter((t) => !SHAPE_TOKENS.includes(t))
  return shape === 'ellipse' ? [...rest, 'ellipse'] : rest
}

/** Set (`fill=<color>`) or clear (`null`) the fill colour, preserving fill opacity. */
export function withFillColor(options: string[], color: string | null): string[] {
  return setKeyed(options, FILL_RE, color === null ? null : `fill=${color}`)
}

/**
 * Turn the stroke on or off. On ensures the node is drawn (adds a bare `draw` unless a
 * `draw=<color>` already draws it); off removes every `draw`/`draw=<color>` token. Stroke
 * knobs (width/dash/draw opacity) are left in place — harmless while undrawn, and restored
 * if the stroke is turned back on.
 */
export function withStroke(options: string[], on: boolean): string[] {
  const rest = options.filter((t) => !DRAW_RE.test(t))
  if (!on) return rest
  return options.some((t) => DRAW_RE.test(t)) ? options : [...rest, 'draw']
}

/** Set the stroke colour (`draw=<color>`) or, on `null`, reset to the default stroke (a bare
 *  `draw`). Either way the node stays drawn. */
export function withStrokeColor(options: string[], color: string | null): string[] {
  const rest = options.filter((t) => !DRAW_RE.test(t))
  return [...rest, color === null ? 'draw' : `draw=${color}`]
}

/** Set the line width to a TikZ named width, or `null` for the default. Drops any prior
 *  named width and any explicit `line width=<pt>`. */
export function withLineWidth(options: string[], name: LineWidthName | null): string[] {
  const rest = options.filter(
    (t) => !LINE_WIDTHS.includes(t as LineWidthName) && !LINE_WIDTH_RE.test(t),
  )
  return name === null ? rest : [...rest, name]
}

/** Set the dash pattern, or `null` for a solid stroke. Drops any prior dash token. */
export function withDash(options: string[], pattern: DashPattern | null): string[] {
  const rest = options.filter((t) => !DASH_PATTERNS.includes(t as DashPattern))
  return pattern === null ? rest : [...rest, pattern]
}

/** Set (`opacity=<n>`) or clear (`null`) the whole-node opacity. */
export function withOpacity(options: string[], value: number | null): string[] {
  return setKeyed(options, OPACITY_RE, value === null ? null : `opacity=${value}`)
}

/** Set (`fill opacity=<n>`) or clear (`null`) the fill-only opacity. */
export function withFillOpacity(options: string[], value: number | null): string[] {
  return setKeyed(options, FILL_OPACITY_RE, value === null ? null : `fill opacity=${value}`)
}

/** Set (`draw opacity=<n>`) or clear (`null`) the stroke-only opacity. */
export function withDrawOpacity(options: string[], value: number | null): string[] {
  return setKeyed(options, DRAW_OPACITY_RE, value === null ? null : `draw opacity=${value}`)
}

/** Set (`rounded corners=<pt>`) or clear (`null`, square) a rectangle's corner radius. */
export function withCorners(options: string[], pt: number | null): string[] {
  return setKeyed(options, ROUNDED_RE, pt === null ? null : `rounded corners=${pt}`)
}

/** Set (`font size=<cqw>`) or clear (`null`, back to the theme role's size) the per-node text
 *  size. `cqw` is slide-relative, like the theme's per-role `size`; the token overrides the
 *  class (class < node). Clearing restores inheritance. Role/placement/other knobs untouched. */
export function withFontSize(options: string[], cqw: number | null): string[] {
  return setKeyed(options, FONT_SIZE_RE, cqw === null ? null : `font size=${cqw}`)
}

/**
 * Replace the first token matching `re` with `token` (or drop it when `token` is null),
 * keeping its position; appends when the node had no such token. The same position-stable
 * splice the engine's size/overlay writers use, so edits stay local and re-serialize cleanly.
 */
function setKeyed(options: string[], re: RegExp, token: string | null): string[] {
  const idx = options.findIndex((t) => re.test(t))
  const without = options.filter((t) => !re.test(t))
  if (token === null) return without
  if (idx === -1) return [...without, token]
  return [...without.slice(0, idx), token, ...without.slice(idx)]
}
