/**
 * Assemble a slide into the layered DOM. Contract: see slide.md.
 *
 * The full render (ADR 0014): an SVG geometry layer (node boxes + `\draw` arrows)
 * under an HTML content layer, sharing one slide(0..16 x 0..9, y-up) -> box mapping.
 * Geometry uses an SVG `viewBox="0 0 16 9"` (y flipped to SVG's y-down); content
 * nodes are absolutely positioned by percentage of the same box, so the two layers
 * register by construction. Pure string output — headless and snapshot-testable.
 *
 * This is where `\draw` path bodies are finally parsed, resolving `(name)` endpoints
 * against the layout anchors (B1). Arrowheads come from the `->`/`<-` path options.
 */
import type { NodeStatement, PathStatement, Point, Statement, TikzPicture } from '../model/tikz'
import type { Layout, PlacedNode } from '../model/layout'
import { anchor as nodeAnchor, findPlaced, isAnchorName } from '../layout/resolve'
import { minHeight, nodeOverlay, nodeScale, opacity } from '../tikz/options'
import { activeAt, contentMaxStep, specMaxStep } from '../content/overlay'
import { parseConnector, type Anchor, type ConnectorPath } from '../tikz/connector'
import { renderContent, type RenderOptions } from './html'
import { shapeGeometrySvg } from './shape'

const SLIDE_W = 16
const SLIDE_H = 9

export function renderSlide(
  picture: TikzPicture,
  layout: Layout,
  options: RenderOptions = {},
): string {
  // Aspect ratio (ADR 0017): height is fixed at 9, width varies (16 = 16:9, 12 = 4:3). The
  // box coords (viewBox, rect x/y) are already in slide units, so only the width matters here
  // and in the x-axis percentages (nodeDiv); the vertical math stays anchored to SLIDE_H.
  const W = options.slideWidth ?? SLIDE_W
  const contentNodes = picture.statements.filter(isNode)
  const boxes = layout.nodes.map((placed, i) => shapeSvg(placed, contentNodes[i]!)).join('')
  const arrows = connectorsOf(picture, layout).map(arrowSvg).join('')
  const svg = `<svg class="sb-geometry" viewBox="0 0 ${r(W)} ${SLIDE_H}" preserveAspectRatio="none">${MARKER_DEFS}${boxes}${arrows}</svg>`
  // Per-slide footnotes: each `\citefootnote` marker numbers in reading order across
  // the slide's nodes (the sink `add` returns the 1-based index); the definitions then
  // collect into a band at the slide foot (Beamer-style), so numbering and placement
  // are a slide-level concern rather than a per-node one.
  const footnotes: string[][] = []
  const withFootnotes: RenderOptions = {
    ...options,
    footnotes: { add: (keys) => footnotes.push(keys) },
  }
  const content = layout.nodes
    .map((placed, i) => nodeDiv(placed, contentNodes[i]!, withFootnotes, W))
    .join('')
  // Inline aspect-ratio overrides the stylesheet default (16/9) so a themed deck renders in
  // its own shape everywhere the slide mounts (canvas, thumbnail, export).
  const shape = W === SLIDE_W ? '' : ` style="aspect-ratio:${r(W)}/${SLIDE_H}"`
  return `<div class="sb-slide"${shape}>${svg}<div class="sb-content">${content}</div>${footnoteBand(footnotes, options)}</div>`
}

/** The slide-foot footnote band: each collected `\citefootnote`, numbered in order.
 *  `renderFootnoteText` (app-supplied, has the bibliography) formats each reference;
 *  absent, the band falls back to the raw keys. Empty -> no band. */
function footnoteBand(footnotes: string[][], options: RenderOptions): string {
  if (footnotes.length === 0) return ''
  const items = footnotes
    .map((keys, i) => {
      const text = options.renderFootnoteText?.(keys) ?? escapeHtml(keys.join(', '))
      return `<div class="sb-footnote"><sup>${i + 1}</sup> ${text}</div>`
    })
    .join('')
  return `<div class="sb-footnotes">${items}</div>`
}

function escapeHtml(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}

/** A resolved connector: its identity (`index` among path statements — what
 *  `deleteConnector` targets), the resolved anchor points, the SVG path data it draws
 *  (with curves), its arrowheads, and the structured `editable` path (`null` when the
 *  body is outside the editable subset — then it renders straight and can't be reshaped). */
export interface Connector {
  index: number
  points: Point[]
  pathData: string
  heads: { start: boolean; end: boolean }
  editable: ConnectorPath | null
}

/** Resolve an anchor to a slide point: a node's current center, or the literal point. */
function resolveAnchor(anchor: Anchor, layout: Layout): Point | null {
  if (anchor.kind === 'point') return anchor.at
  const placed = findPlaced(layout, anchor.name)
  if (!placed) return null
  // A border port (`(name.north)`) resolves to that edge; otherwise the node centre.
  return anchor.anchor && isAnchorName(anchor.anchor)
    ? nodeAnchor(placed, anchor.anchor)
    : placed.center
}

/**
 * Resolve every drawable connector against the layout. Node endpoints resolve to the
 * node's current center (so a connector re-routes for free when its node moves); the
 * editable subset (straight + cubic segments) also yields a structured `ConnectorPath`.
 * Shared by the renderer and the editor so the two never disagree about an arrow.
 */
export function connectorsOf(picture: TikzPicture, layout: Layout): Connector[] {
  const connectors: Connector[] = []
  let index = -1
  for (const statement of picture.statements) {
    if (!isPath(statement)) continue
    index++ // index among path statements — stable identity for deleteConnector
    if (statement.action !== 'draw' && statement.action !== 'path') continue
    const heads = arrowHeads(statement.options)
    const parsed = parseConnector(statement.body)
    const resolved = parsed?.anchors.map((a) => resolveAnchor(a, layout))
    if (parsed && resolved && resolved.every((p): p is Point => p !== null)) {
      connectors.push({
        index,
        points: resolved,
        pathData: curvePathData(resolved, parsed.curves),
        heads,
        editable: parsed,
      })
      continue
    }
    // Fallback: unresolved anchor or a body outside the subset — render straight, no edit.
    const points = connectorPoints(statement.body, layout)
    if (points.length < 2) continue
    connectors.push({ index, points, pathData: polyPathData(points), heads, editable: null })
  }
  return connectors
}

/** SVG path data for a (possibly curved) connector, y flipped to the viewBox. */
function curvePathData(points: Point[], curves: ConnectorPath['curves']): string {
  let d = `M ${r(points[0]!.x)},${r(SLIDE_H - points[0]!.y)}`
  for (let i = 1; i < points.length; i++) {
    const curve = curves[i - 1]
    const to = `${r(points[i]!.x)},${r(SLIDE_H - points[i]!.y)}`
    d += curve
      ? ` C ${r(curve.c1.x)},${r(SLIDE_H - curve.c1.y)} ${r(curve.c2.x)},${r(SLIDE_H - curve.c2.y)} ${to}`
      : ` L ${to}`
  }
  return d
}

/** SVG path data for a straight polyline (the non-editable fallback). */
function polyPathData(points: Point[]): string {
  return points.map((p, i) => `${i === 0 ? 'M' : 'L'} ${r(p.x)},${r(SLIDE_H - p.y)}`).join(' ')
}

/** The geometry box for a placed node: its shape outline (rect/ellipse), stroked when the
 *  source node carries `draw`. Maps the node box out of slide space (y-up) into the SVG
 *  viewBox (y-down), then defers the element choice + stroke/fill to `shapeGeometrySvg` —
 *  the same function the shapes palette draws its thumbnails with. */
function shapeSvg(node: PlacedNode, source: NodeStatement): string {
  const rect = {
    x: node.center.x - node.size.width / 2,
    y: SLIDE_H - node.center.y - node.size.height / 2,
    width: node.size.width,
    height: node.size.height,
  }
  return shapeGeometrySvg(
    source,
    rect,
    node.styleClasses.map((c) => `sb-style-${c}`),
  )
}

function nodeDiv(
  node: PlacedNode,
  source: NodeStatement,
  options: RenderOptions,
  slideWidth: number = SLIDE_W,
): string {
  const scale = nodeScale(source)
  const left = pct(node.center.x - node.size.width / 2, slideWidth)
  const top = pct(SLIDE_H - node.center.y - node.size.height / 2, SLIDE_H)
  // Content is laid out at its NATURAL width (the box already folds in the scale), then a
  // CSS transform scales it up to fill the box — so text, tables, and images all grow with
  // the box, not just the frame. `size.width / scale.x` recovers the pre-scale width.
  const width = pct(node.size.width / scale.x, slideWidth)
  // `minimum height` occupies the box down to that floor while still growing with content
  // (grow-only). In natural units (the transform scales it with everything else).
  const mh = minHeight(source)
  const minH = mh !== undefined ? `;min-height:${pct(mh, SLIDE_H)}%` : ''
  const scaled =
    scale.x !== 1 || scale.y !== 1
      ? `;transform-origin:top left;transform:scale(${r(scale.x)},${r(scale.y)})`
      : ''
  // Whole-node `opacity` dims the content in step with the SVG box's `opacity`.
  const op = opacity(source)
  const opStyle = op !== undefined ? `;opacity:${r(op)}` : ''
  // Model identity in the DOM: lets an editor hit-test and address this node
  // (selection, drag, inline edit). Harmless in the export DOM (ADR 0014).
  const id = source.name !== undefined ? ` data-node="${source.name}"` : ''
  // Whole-node overlay (ADR 0018): hidden with space reserved when its spec is inactive at
  // the rendered step; absent step (authoring) shows every node. `data-overlay` addresses it.
  const overlay = nodeOverlay(source)
  const ovHidden =
    overlay !== undefined && options.step !== undefined && !activeAt(overlay, options.step)
  const ovClass = ovHidden ? ' sb-ov-hidden' : ''
  const ovData =
    overlay !== undefined ? ` data-overlay="${overlay.raw.replace(/"/g, '&quot;')}"` : ''
  return `<div class="${nodeClass(node)}${ovClass}"${id}${ovData} style="left:${left}%;top:${top}%;width:${width}%${minH}${scaled}${opStyle}">${renderContent(source.content, options)}</div>`
}

/**
 * The number of overlay steps a slide plays as (ADR 0018): the largest step any node
 * references — through its `overlay=<spec>` option or its inline content (`\pause`,
 * `\only<spec>`, `\item<spec>`, …) — and always at least 1. Drives the step navigator and
 * the one-page-per-step export.
 */
export function slideStepCount(picture: TikzPicture): number {
  let max = 1
  for (const statement of picture.statements) {
    if (statement.kind !== 'node') continue
    const overlay = nodeOverlay(statement)
    if (overlay !== undefined) max = Math.max(max, specMaxStep(overlay))
    max = Math.max(max, contentMaxStep(statement.content))
  }
  return max
}

function arrowSvg(connector: Connector): string {
  const markers = [
    connector.heads.start ? 'marker-start="url(#sb-arrow-start)"' : '',
    connector.heads.end ? 'marker-end="url(#sb-arrow-end)"' : '',
  ]
    .filter(Boolean)
    .join(' ')
  // data-arrow: model identity in the DOM so an editor can hit-test / address it
  // (like data-node). Harmless in the export DOM (ADR 0014).
  return `<path class="sb-arrow" data-arrow="${connector.index}" d="${connector.pathData}"${markers ? ' ' + markers : ''}/>`
}

/** Endpoints of a straight-segment connector body: `(name)` -> node center, `(x,y)` -> point. */
function connectorPoints(body: string, layout: Layout): Point[] {
  const points: Point[] = []
  for (const token of body.split(/--|-\||\|-/)) {
    const m = /^\s*\(([^)]*)\)/.exec(token)
    if (m === null) continue
    const inner = m[1]!.trim()
    if (/^-?[\d.]+\s*,\s*-?[\d.]+$/.test(inner)) {
      const [x, y] = inner.split(',').map(Number)
      points.push({ x: x!, y: y! })
    } else {
      const node = findPlaced(layout, inner)
      if (node !== undefined) points.push(node.center)
    }
  }
  return points
}

function arrowHeads(options: string[]): { start: boolean; end: boolean } {
  const tips = options.join(' ')
  return { start: tips.includes('<-') || tips.includes('<->'), end: tips.includes('->') }
}

const MARKER_DEFS =
  '<defs>' +
  '<marker id="sb-arrow-end" markerWidth="6" markerHeight="6" refX="5" refY="3" orient="auto"><path d="M0,0 L6,3 L0,6 z"/></marker>' +
  '<marker id="sb-arrow-start" markerWidth="6" markerHeight="6" refX="1" refY="3" orient="auto-start-reverse"><path d="M0,0 L6,3 L0,6 z"/></marker>' +
  '</defs>'

/** A minimal base stylesheet so the layered DOM is actually viewable when mounted. */
export function slideStylesheet(): string {
  return [
    '.sb-slide{position:relative;aspect-ratio:16/9;width:100%;background:#fff;overflow:hidden}',
    '.sb-geometry{position:absolute;inset:0;width:100%;height:100%}',
    '.sb-content{position:absolute;inset:0}',
    '.sb-node{position:absolute;box-sizing:border-box}',
    // A node box is invisible by default (text/title nodes have no outline). A shape carries
    // `draw`, adding `sb-drawn` for a visible stroke; `fill=<color>` sets an inline fill.
    '.sb-box{fill:transparent;stroke:none}',
    '.sb-drawn{stroke:#333;stroke-width:0.03;stroke-linejoin:round}',
    '.sb-arrow{fill:none;stroke:#333;stroke-width:0.03}',
    // columns lay out as a flex row; each `.sb-column` carries an inline `flex:<width>`
    // (from its `\column{…}` argument) so widths are proportional. min-width:0 lets a
    // column shrink and wrap instead of overflowing the node box.
    '.sb-columns{display:flex;gap:1em;align-items:flex-start}',
    '.sb-column{min-width:0}',
    // a matrix is a spacing-only grid of cells (no rules), matrix-style centred.
    '.sb-matrix{border-collapse:collapse;margin:0.1em 0}',
    '.sb-matrix td{padding:0.1em 0.5em;vertical-align:middle;text-align:center}',
    // Overlays (ADR 0018): hidden content keeps its space (never reflows); alert highlights.
    '.sb-ov-hidden{visibility:hidden}',
    '.sb-ov-alert{color:#c0392b}',
    '.sb-deferred,.sb-include,.sb-error,.sb-table-error{opacity:0.7;font-style:italic}',
    // a compiled table (Compile port) carries its own latexml <style>; keep its box tidy.
    '.sb-table{display:inline-block;font-style:normal}',
    // citations: inline marker, superscript footnote marker, and the slide-foot band.
    '.sb-cite{white-space:nowrap}',
    '.sb-fn-marker{font-size:0.7em;line-height:0}',
    '.sb-bibliography{font-size:0.8em}',
    '.sb-footnotes{position:absolute;left:0;right:0;bottom:0;padding:0.4em 2%;font-size:0.55em;' +
      'line-height:1.3;border-top:0.05cqw solid #ccc;color:#333;background:rgba(255,255,255,0.85)}',
    '.sb-footnote{text-indent:-1em;padding-left:1em}',
    '.sb-footnote sup{margin-right:0.3em}',
  ].join('\n')
}

function nodeClass(node: PlacedNode): string {
  return ['sb-node', ...node.styleClasses.map((c) => `sb-style-${c}`)].join(' ')
}

function isNode(s: Statement): s is NodeStatement {
  return s.kind === 'node'
}

function isPath(s: Statement): s is PathStatement {
  return s.kind === 'path'
}

/** Round to 4 decimals and trim trailing zeros, for stable, compact output. */
function r(n: number): string {
  return String(Number(n.toFixed(4)))
}

function pct(value: number, total: number): string {
  return r((value / total) * 100)
}
