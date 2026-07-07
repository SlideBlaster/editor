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
  strokeColor,
  strokeWidthUnits,
} from '../tikz/options'

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

  if (nodeShape(node) === 'ellipse') {
    const cx = rect.x + rect.width / 2
    const cy = rect.y + rect.height / 2
    return `<ellipse class="${classes}" cx="${r(cx)}" cy="${r(cy)}" rx="${r(rect.width / 2)}" ry="${r(rect.height / 2)}"${style}/>`
  }
  const radius = cornerRadiusUnits(node)
  const rounded = radius !== undefined ? ` rx="${r(radius)}" ry="${r(radius)}"` : ''
  return `<rect class="${classes}" x="${r(rect.x)}" y="${r(rect.y)}" width="${r(rect.width)}" height="${r(rect.height)}"${rounded}${style}/>`
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
