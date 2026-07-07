/**
 * Derived, read-only views over a node's raw option tokens. Contract: see
 * options.md. These recompute from `NodeStatement.options` (the serialization
 * truth) so they never desynchronize; nothing here is stored on the model.
 */
import type { NodeStatement } from '../model/tikz'
import type { OverlaySpec } from '../model/content'

/** Bare (non `key=value`) tokens that name a style class, e.g. `title`, `body`. */
export function styleClasses(node: NodeStatement): string[] {
  return node.options.filter((token) => !token.includes('=') && !/^[<|>.-]+$/.test(token))
}

/**
 * The node's whole-node overlay reveal spec, from an `overlay=<spec>` option token (ADR
 * 0018) — the properties-panel half of the two-level model. The value is stored
 * brace-wrapped (`overlay={1,3}`) so a spec's commas survive option tokenizing; `<…>` is
 * also accepted. Returns the raw spec (interpreted by `content/overlay`), or undefined.
 */
export function nodeOverlay(node: NodeStatement): OverlaySpec | undefined {
  const token = node.options.find((t) => /^overlay\s*=/.test(t))
  if (token === undefined) return undefined
  let raw = token.slice(token.indexOf('=') + 1).trim()
  if ((raw.startsWith('{') && raw.endsWith('}')) || (raw.startsWith('<') && raw.endsWith('>'))) {
    raw = raw.slice(1, -1).trim()
  }
  return raw === '' ? undefined : { raw }
}

/** The `title` style class marks the slide's title node. */
export function role(node: NodeStatement): 'title' | undefined {
  return styleClasses(node).includes('title') ? 'title' : undefined
}

/** Whether a raw option token is a relative placement (`below=0.7 of title`). */
export function isPlacementToken(token: string): boolean {
  return /^(above|below|left|right)\b.*=.*\bof\b/.test(token)
}

/** The first relative-placement token (`below=0.7 of title`), if any. */
export function placementToken(node: NodeStatement): string | undefined {
  return node.options.find(isPlacementToken)
}

/** Default gap (slide units) for a relative placement written without a distance. */
export const DEFAULT_PLACEMENT_GAP = 0.5

export interface Placement {
  side: 'above' | 'below' | 'left' | 'right'
  gap: number
  ref: string
}

/**
 * Structured read of the relative-placement token: `below=0.7 of title`. A token that
 * omits the distance (`below= of title`) takes `defaultGap` — the theme's node distance
 * (ADR 0017), which defaults to `DEFAULT_PLACEMENT_GAP`.
 */
export function placement(
  node: NodeStatement,
  defaultGap: number = DEFAULT_PLACEMENT_GAP,
): Placement | undefined {
  const token = placementToken(node)
  if (token === undefined) return undefined
  const m = /^(above|below|left|right)\s*=\s*([\d.]*)\s*of\s+(\S+)/.exec(token)
  if (m === null) return undefined
  const gap = m[2] ? Number(m[2]) : defaultGap
  return {
    side: m[1] as Placement['side'],
    gap: Number.isNaN(gap) ? defaultGap : gap,
    ref: m[3]!,
  }
}

/** The `text width=<n>` value in slide units, if the node fixes its width. */
export function textWidth(node: NodeStatement): number | undefined {
  return numericOption(node, /^text\s+width\s*=/)
}

/**
 * The `minimum height=<n>` value in slide units, if the node sets a height floor. The
 * height counterpart to `text width`: grow-only, so content taller than `<n>` still
 * expands the box (the measurer takes `max(content, minimum height)`).
 */
export function minHeight(node: NodeStatement): number | undefined {
  return numericOption(node, /^minimum\s+height\s*=/)
}

/**
 * The `minimum width=<n>` value in slide units, if the node sets a width floor — the
 * width counterpart to `minimum height`. Grow-only: content wider than `<n>` still
 * expands the box. This is the size lever shapes use so a dropped, empty shape lands
 * at a visible default size (rather than collapsing to a caret).
 */
export function minWidth(node: NodeStatement): number | undefined {
  return numericOption(node, /^minimum\s+width\s*=/)
}

/** The geometric outline a node draws — the shape switch the renderer maps to an SVG
 *  element and the catalogue selects with an option preset (tikz-subset.md). `rectangle` is
 *  the default box; `ellipse` covers circles; the straight-edged outlines all render as one
 *  `<polygon>`; `cylinder` as a `<path>`; `stadium` (a pill / flowchart terminator) as a
 *  fully-rounded `<rect>`. */
export type NodeShape =
  | 'rectangle'
  | 'ellipse'
  | 'diamond'
  | 'triangle'
  | 'trapezoid'
  | 'parallelogram'
  | 'regularPolygon'
  | 'cylinder'
  | 'stadium'
  | 'stencil'

/** Bare shape tokens and the `NodeShape` each selects, in detection order (first match wins).
 *  `circle` renders as an equal-radii ellipse; `rounded rectangle` as a stadium. These tokens
 *  and their kin are style KNOBS (see `STYLE_KNOB_TOKENS`), never theme roles. */
const SHAPE_TOKENS: ReadonlyArray<readonly [token: string, shape: NodeShape]> = [
  ['ellipse', 'ellipse'],
  ['circle', 'ellipse'],
  ['diamond', 'diamond'],
  ['isosceles triangle', 'triangle'],
  ['triangle', 'triangle'],
  ['trapezium', 'trapezoid'],
  ['parallelogram', 'parallelogram'],
  ['regular polygon', 'regularPolygon'],
  ['cylinder', 'cylinder'],
  ['rounded rectangle', 'stadium'],
]

/** The node's shape. An imported stencil (`stencil=<id>`) wins over the bare shape tokens
 *  (it is a `key=value` token, invisible to `styleClasses`); otherwise the first matching
 *  bare shape token decides; defaults to `rectangle`. */
export function nodeShape(node: NodeStatement): NodeShape {
  if (stencilId(node) !== undefined) return 'stencil'
  const classes = styleClasses(node)
  for (const [token, shape] of SHAPE_TOKENS) if (classes.includes(token)) return shape
  return 'rectangle'
}

/** The imported-stencil id from a `stencil=<id>` option token (e.g. `flowchart.decision`),
 *  else undefined. The renderer resolves it to a path via the stencil registry
 *  (`render/stencils`); the token round-trips verbatim as raw option text. */
export function stencilId(node: NodeStatement): string | undefined {
  const token = node.options.find((t) => /^stencil\s*=/.test(t))
  return token === undefined ? undefined : token.slice(token.indexOf('=') + 1).trim() || undefined
}

/** The `regular polygon sides=<n>` count for a regular-polygon node (clamped to >= 3);
 *  default 5, matching TikZ. Drives how many `<polygon>` points the renderer emits. */
export function polygonSides(node: NodeStatement): number {
  const n = numericOption(node, /^regular\s+polygon\s+sides\s*=/)
  return n !== undefined && n >= 3 ? Math.floor(n) : 5
}

/** Whether the node paints a visible outline — a bare `draw` or a `draw=<color>` option
 *  (setting a stroke colour implies drawing it, as in TikZ). A plain (text) node has
 *  neither, so its box stays invisible; a shape carries `draw` to be seen. */
export function isDrawn(node: NodeStatement): boolean {
  return node.options.some((t) => t === 'draw' || /^draw\s*=/.test(t))
}

/** The `fill=<color>` value if the node paints a fill, else undefined. The color is a raw
 *  token (a CSS/TikZ color name or hex) passed straight through to the SVG `fill`. */
export function fillColor(node: NodeStatement): string | undefined {
  return colorOption(node, /^fill\s*=/)
}

/** The stroke colour from a `draw=<color>` option, else undefined (a bare `draw`, or no
 *  stroke, leaves the stylesheet's default stroke). Passed straight to the SVG `stroke`. */
export function strokeColor(node: NodeStatement): string | undefined {
  return colorOption(node, /^draw\s*=/)
}

/**
 * TikZ named line widths, thinnest to thickest, with their pt values (the standard TikZ
 * table). The style panel offers these names; the renderer maps the chosen width to an SVG
 * stroke width in slide units. `line width=<pt>` is the explicit numeric escape hatch.
 */
export const LINE_WIDTHS = [
  'ultra thin',
  'very thin',
  'thin',
  'semithick',
  'thick',
  'very thick',
  'ultra thick',
] as const
export type LineWidthName = (typeof LINE_WIDTHS)[number]

const LINE_WIDTH_PT: Record<LineWidthName, number> = {
  'ultra thin': 0.1,
  'very thin': 0.2,
  thin: 0.4,
  semithick: 0.6,
  thick: 0.8,
  'very thick': 1.2,
  'ultra thick': 1.6,
}

/** Slide-units per TikZ point, for stroke widths and corner radii. Anchored so `thin`
 *  (TikZ's default) resolves to the base 0.03-unit stroke the stylesheet already uses,
 *  keeping an undrawn->drawn box's default weight unchanged. */
const PT_TO_UNITS = 0.03 / LINE_WIDTH_PT.thin

/** The node's line width as a TikZ name, if it carries one of `LINE_WIDTHS`, else undefined. */
export function lineWidthName(node: NodeStatement): LineWidthName | undefined {
  const classes = styleClasses(node)
  return LINE_WIDTHS.find((w) => classes.includes(w))
}

/** The explicit `line width=<pt>` value in pt, if set (the numeric escape hatch). */
export function lineWidthPt(node: NodeStatement): number | undefined {
  return lengthOption(node, /^line\s+width\s*=/)
}

/**
 * Resolved stroke width in slide units for the renderer: an explicit `line width=<pt>`
 * wins, else a named width, else undefined (the stylesheet default 0.03 applies).
 */
export function strokeWidthUnits(node: NodeStatement): number | undefined {
  const pt = lineWidthPt(node)
  if (pt !== undefined) return pt * PT_TO_UNITS
  const name = lineWidthName(node)
  return name === undefined ? undefined : LINE_WIDTH_PT[name] * PT_TO_UNITS
}

/** TikZ dash patterns, in panel order. Bare option tokens (e.g. `densely dashed`); absent
 *  means a solid stroke. */
export const DASH_PATTERNS = [
  'dashed',
  'densely dashed',
  'loosely dashed',
  'dotted',
  'densely dotted',
  'loosely dotted',
] as const
export type DashPattern = (typeof DASH_PATTERNS)[number]

/** The node's dash pattern if it carries one, else undefined (solid). */
export function dashPattern(node: NodeStatement): DashPattern | undefined {
  const classes = styleClasses(node)
  return DASH_PATTERNS.find((d) => classes.includes(d))
}

/**
 * How a dash pattern renders as an SVG stroke: a `stroke-dasharray` (in slide units) and
 * whether the caps are round. Dotted patterns use a near-zero dash with round caps so each
 * dash paints a round dot the width of the stroke.
 */
export function dashArray(pattern: DashPattern): { array: string; round: boolean } {
  switch (pattern) {
    case 'dashed':
      return { array: '0.15,0.1', round: false }
    case 'densely dashed':
      return { array: '0.15,0.06', round: false }
    case 'loosely dashed':
      return { array: '0.15,0.18', round: false }
    case 'dotted':
      return { array: '0.001,0.08', round: true }
    case 'densely dotted':
      return { array: '0.001,0.05', round: true }
    case 'loosely dotted':
      return { array: '0.001,0.14', round: true }
  }
}

/** Whole-node `opacity=<0..1>`, if set. Dims both the box and its content. */
export function opacity(node: NodeStatement): number | undefined {
  return numericOption(node, /^opacity\s*=/)
}

/** `fill opacity=<0..1>`, if set — the fill's alpha independent of the stroke. */
export function fillOpacity(node: NodeStatement): number | undefined {
  return numericOption(node, /^fill\s+opacity\s*=/)
}

/** `draw opacity=<0..1>`, if set — the stroke's alpha independent of the fill. */
export function drawOpacity(node: NodeStatement): number | undefined {
  return numericOption(node, /^draw\s+opacity\s*=/)
}

/** TikZ's default `rounded corners` radius in pt (used by a bare `rounded corners`). */
export const DEFAULT_ROUNDED_PT = 4

/** The `rounded corners[=<pt>]` radius in pt (a bare token takes `DEFAULT_ROUNDED_PT`),
 *  else undefined (square corners). Only rectangles honour it. */
export function cornerRadiusPt(node: NodeStatement): number | undefined {
  const token = node.options.find((t) => /^rounded\s+corners\b/.test(t))
  if (token === undefined) return undefined
  if (!token.includes('=')) return DEFAULT_ROUNDED_PT
  const n = Number.parseFloat(token.slice(token.indexOf('=') + 1).trim())
  return Number.isNaN(n) ? DEFAULT_ROUNDED_PT : n
}

/** The corner radius in slide units for the renderer's rect `rx`/`ry`, else undefined. */
export function cornerRadiusUnits(node: NodeStatement): number | undefined {
  const pt = cornerRadiusPt(node)
  return pt === undefined ? undefined : pt * PT_TO_UNITS
}

/** The bare option tokens that name a style KNOB (shape/paint/width/dash), as opposed to a
 *  theme role. `styleClasses` surfaces both as bare tokens, so callers that mean "the
 *  theme role" (the style dropdown) or "the role classes to keep" (`setNodeStyleClass`)
 *  use this to tell a knob like `draw`/`ellipse`/`thick`/`dashed` apart from a role. */
const STYLE_KNOB_TOKENS: ReadonlySet<string> = new Set<string>([
  'draw',
  'rectangle',
  'rounded corners',
  ...SHAPE_TOKENS.map(([token]) => token),
  ...LINE_WIDTHS,
  ...DASH_PATTERNS,
])
export function isStyleKnobToken(token: string): boolean {
  return STYLE_KNOB_TOKENS.has(token)
}

/**
 * The node's content scale on each axis (default 1). TikZ multiplies a bare `scale=<k>`
 * into both axes and `xscale`/`yscale` per axis; resize writes these so the rendered
 * content (text, tables, images) grows with the box. `{ x: 1, y: 1 }` means natural size.
 */
export function nodeScale(node: NodeStatement): { x: number; y: number } {
  const base = numericOption(node, /^scale\s*=/) ?? 1
  const sx = numericOption(node, /^xscale\s*=/) ?? 1
  const sy = numericOption(node, /^yscale\s*=/) ?? 1
  return { x: base * sx, y: base * sy }
}

/** The numeric value of the first `key=<n>` option token matching `re`, else undefined. */
function numericOption(node: NodeStatement, re: RegExp): number | undefined {
  const token = node.options.find((t) => re.test(t))
  if (token === undefined) return undefined
  const n = Number(token.slice(token.indexOf('=') + 1).trim())
  return Number.isNaN(n) ? undefined : n
}

/** Like `numericOption` but tolerant of a trailing TikZ unit (`0.8pt`) via `parseFloat`. */
function lengthOption(node: NodeStatement, re: RegExp): number | undefined {
  const token = node.options.find((t) => re.test(t))
  if (token === undefined) return undefined
  const n = Number.parseFloat(token.slice(token.indexOf('=') + 1).trim())
  return Number.isNaN(n) ? undefined : n
}

/** The raw colour token of the first `key=<color>` option matching `re`, else undefined. */
function colorOption(node: NodeStatement, re: RegExp): string | undefined {
  const token = node.options.find((t) => re.test(t))
  return token === undefined ? undefined : token.slice(token.indexOf('=') + 1).trim() || undefined
}
