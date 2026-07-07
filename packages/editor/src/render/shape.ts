/**
 * Shape geometry: a node's box rendered as a visible SVG outline. Contract: see shape.md.
 *
 * The geometry half of a shape. A slide is one TikZ picture and a shape is just a `\node`
 * with shape options (ADR 0004, tikz-subset.md) — nothing new in the model. This reads a
 * node's style options — `nodeShape` (which SVG element), `isDrawn` (a visible stroke),
 * `fillColor` (a fill) — and emits ONE SVG element sized to `rect`.
 *
 * Pure and self-contained: the slide renderer feeds it a rect already mapped into the
 * slide viewBox (y-down); the shapes palette feeds it a rect in its own preview viewBox.
 * So a dropped shape on the canvas and its palette thumbnail are drawn by the SAME code —
 * they can never diverge. Growing the shape vocabulary is one new `NodeShape` case here
 * plus one catalogue entry; the rest of the pipeline is untouched.
 */
import type { NodeStatement } from '../model/tikz'
import {
  cornerRadiusUnits,
  dashArray,
  dashPattern,
  drawOpacity,
  fillColor,
  fillOpacity,
  isDrawn,
  nodeShape,
  opacity,
  polygonSides,
  stencilId,
  strokeColor,
  strokeWidthUnits,
  type NodeShape,
} from '../tikz/options'
import { placeStencilPath, stencilPath } from './stencils'

/** A box in SVG user units (y-down, top-left origin) — already mapped out of slide space. */
export interface Rect {
  x: number
  y: number
  width: number
  height: number
}

/**
 * One SVG element for `node`'s box, sized to `rect`. Class order is `sb-box`, then
 * `sb-drawn` when the node is drawn (a stroke, given its default weight/colour by the
 * stylesheet), then any `extraClasses` (the slide renderer passes the node's `sb-style-*`;
 * the palette passes none).
 *
 * Every style knob is emitted as an inline `style` declaration, because inline CSS is what
 * beats the `.sb-drawn` stylesheet rule (SVG presentation attributes would lose to it):
 * `fill`/`fill-opacity` for the fill, and — only when the node is drawn — `stroke`,
 * `stroke-width`, `stroke-dasharray` (+ round `stroke-linecap` for dotted), and
 * `stroke-opacity`; a whole-node `opacity` dims both. A rectangle's `rounded corners`
 * become geometric `rx`/`ry` attributes. An undrawn, unfilled node still emits its element
 * so selection/hit-test geometry is unchanged from a plain box.
 */
export function shapeGeometrySvg(
  node: NodeStatement,
  rect: Rect,
  extraClasses: string[] = [],
): string {
  const drawn = isDrawn(node)
  const classes = ['sb-box', ...(drawn ? ['sb-drawn'] : []), ...extraClasses].join(' ')

  const decls: string[] = []
  const fill = fillColor(node)
  if (fill !== undefined) decls.push(`fill:${escapeAttr(fill)}`)
  const fillOp = fillOpacity(node)
  if (fillOp !== undefined) decls.push(`fill-opacity:${r(fillOp)}`)
  if (drawn) {
    const stroke = strokeColor(node)
    if (stroke !== undefined) decls.push(`stroke:${escapeAttr(stroke)}`)
    const width = strokeWidthUnits(node)
    if (width !== undefined) decls.push(`stroke-width:${r(width)}`)
    const dash = dashPattern(node)
    if (dash !== undefined) {
      const { array, round } = dashArray(dash)
      decls.push(`stroke-dasharray:${array}`)
      if (round) decls.push('stroke-linecap:round')
    }
    const drawOp = drawOpacity(node)
    if (drawOp !== undefined) decls.push(`stroke-opacity:${r(drawOp)}`)
  }
  const op = opacity(node)
  if (op !== undefined) decls.push(`opacity:${r(op)}`)
  const style = decls.length ? ` style="${decls.join(';')}"` : ''

  const shape = nodeShape(node)
  if (shape === 'stencil') {
    const d = stencilPath(stencilId(node) ?? '')
    // An imported stencil is its normalized path placed into the box, in absolute units.
    // An unknown id falls through to the default box so the node keeps its hit geometry.
    if (d !== undefined) {
      return `<path class="${classes}" d="${placeStencilPath(d, rect)}"${style}/>`
    }
  }
  if (shape === 'ellipse') {
    const cx = rect.x + rect.width / 2
    const cy = rect.y + rect.height / 2
    return `<ellipse class="${classes}" cx="${r(cx)}" cy="${r(cy)}" rx="${r(rect.width / 2)}" ry="${r(rect.height / 2)}"${style}/>`
  }
  if (POLYGON_SHAPES.has(shape)) {
    const points = polygonPoints(shape, rect, polygonSides(node))
    return `<polygon class="${classes}" points="${points}"${style}/>`
  }
  if (shape === 'cylinder') {
    return `<path class="${classes}" d="${cylinderPath(rect)}"${style}/>`
  }
  // rectangle (with optional `rounded corners`) or stadium (fully rounded — a pill).
  const radius =
    shape === 'stadium' ? Math.min(rect.width, rect.height) / 2 : cornerRadiusUnits(node)
  const rounded = radius !== undefined ? ` rx="${r(radius)}" ry="${r(radius)}"` : ''
  return `<rect class="${classes}" x="${r(rect.x)}" y="${r(rect.y)}" width="${r(rect.width)}" height="${r(rect.height)}"${rounded}${style}/>`
}

/** The straight-edged outlines, all rendered as one `<polygon>` (a different point list each). */
const POLYGON_SHAPES: ReadonlySet<NodeShape> = new Set<NodeShape>([
  'diamond',
  'triangle',
  'trapezoid',
  'parallelogram',
  'regularPolygon',
])

/** The `points` attribute for a polygon shape inscribed in `rect`. Straight-edged shapes are
 *  fixed vertex formulas; a regular polygon walks `sides` points around the box's inscribed
 *  ellipse, first vertex at the top (TikZ orientation). */
function polygonPoints(shape: NodeShape, rect: Rect, sides: number): string {
  const { x, y, width: w, height: h } = rect
  const pts: Array<[number, number]> =
    shape === 'diamond'
      ? [
          [x + w / 2, y],
          [x + w, y + h / 2],
          [x + w / 2, y + h],
          [x, y + h / 2],
        ]
      : shape === 'triangle'
        ? [
            [x + w / 2, y],
            [x + w, y + h],
            [x, y + h],
          ]
        : shape === 'trapezoid'
          ? [
              [x + w * 0.25, y],
              [x + w * 0.75, y],
              [x + w, y + h],
              [x, y + h],
            ]
          : shape === 'parallelogram'
            ? [
                [x + w * 0.25, y],
                [x + w, y],
                [x + w * 0.75, y + h],
                [x, y + h],
              ]
            : regularPolygonPoints(rect, sides)
  return pts.map(([px, py]) => `${r(px)},${r(py)}`).join(' ')
}

/** `sides` points of a regular polygon inscribed in `rect`'s ellipse, first vertex at top. */
function regularPolygonPoints(rect: Rect, sides: number): Array<[number, number]> {
  const cx = rect.x + rect.width / 2
  const cy = rect.y + rect.height / 2
  const rx = rect.width / 2
  const ry = rect.height / 2
  const pts: Array<[number, number]> = []
  for (let i = 0; i < sides; i++) {
    const a = -Math.PI / 2 + (i * 2 * Math.PI) / sides
    pts.push([cx + rx * Math.cos(a), cy + ry * Math.sin(a)])
  }
  return pts
}

/** SVG path for a database cylinder in `rect`: a full top ellipse, two side walls, and a
 *  front bottom arc. `ry` is the elliptical cap depth (clamped so tall/short boxes stay sane). */
function cylinderPath(rect: Rect): string {
  const { x, y, width: w, height: h } = rect
  const rx = w / 2
  const ry = Math.min(h * 0.16, rx * 0.6)
  const topY = y + ry
  const botY = y + h - ry
  return [
    // full top ellipse (two arcs, same sweep, endpoints swapped)
    `M ${r(x)},${r(topY)}`,
    `A ${r(rx)},${r(ry)} 0 0 0 ${r(x + w)},${r(topY)}`,
    `A ${r(rx)},${r(ry)} 0 0 0 ${r(x)},${r(topY)}`,
    `Z`,
    // side walls + front bottom curve
    `M ${r(x)},${r(topY)}`,
    `L ${r(x)},${r(botY)}`,
    `A ${r(rx)},${r(ry)} 0 0 1 ${r(x + w)},${r(botY)}`,
    `L ${r(x + w)},${r(topY)}`,
  ].join(' ')
}

/** Escape a raw color token for an attribute/style context. Colors are simple tokens; this
 *  just keeps a stray quote or bracket from breaking out of the attribute. */
function escapeAttr(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;')
}

/** Round to 4 decimals and trim trailing zeros, for stable, compact output. */
function r(n: number): string {
  return String(Number(n.toFixed(4)))
}
