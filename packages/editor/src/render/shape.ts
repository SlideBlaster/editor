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
import { fillColor, isDrawn, nodeShape } from '../tikz/options'

/** A box in SVG user units (y-down, top-left origin) — already mapped out of slide space. */
export interface Rect {
  x: number
  y: number
  width: number
  height: number
}

/**
 * One SVG element for `node`'s box, sized to `rect`. Class order is `sb-box`, then
 * `sb-drawn` when the node carries `draw` (a stroke, styled by the stylesheet), then any
 * `extraClasses` (the slide renderer passes the node's `sb-style-*`; the palette passes
 * none). A `fill=<color>` is emitted as an inline `style` (which beats the class `fill`),
 * else the box stays transparent. An undrawn, unfilled node still emits its element so
 * selection/hit-test geometry is unchanged from a plain box.
 */
export function shapeGeometrySvg(
  node: NodeStatement,
  rect: Rect,
  extraClasses: string[] = [],
): string {
  const classes = ['sb-box', ...(isDrawn(node) ? ['sb-drawn'] : []), ...extraClasses].join(' ')
  const fill = fillColor(node)
  const style = fill !== undefined ? ` style="fill:${escapeAttr(fill)}"` : ''
  if (nodeShape(node) === 'ellipse') {
    const cx = rect.x + rect.width / 2
    const cy = rect.y + rect.height / 2
    return `<ellipse class="${classes}" cx="${r(cx)}" cy="${r(cy)}" rx="${r(rect.width / 2)}" ry="${r(rect.height / 2)}"${style}/>`
  }
  return `<rect class="${classes}" x="${r(rect.x)}" y="${r(rect.y)}" width="${r(rect.width)}" height="${r(rect.height)}"${style}/>`
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
