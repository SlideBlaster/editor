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
import { findPlaced } from '../layout/resolve'
import { parseConnector, type Anchor, type ConnectorPath } from '../tikz/connector'
import { renderContent, type RenderOptions } from './html'

const SLIDE_W = 16
const SLIDE_H = 9

export function renderSlide(
  picture: TikzPicture,
  layout: Layout,
  options: RenderOptions = {},
): string {
  const contentNodes = picture.statements.filter(isNode)
  const boxes = layout.nodes.map(rectSvg).join('')
  const arrows = connectorsOf(picture, layout).map(arrowSvg).join('')
  const svg = `<svg class="sb-geometry" viewBox="0 0 ${SLIDE_W} ${SLIDE_H}" preserveAspectRatio="none">${MARKER_DEFS}${boxes}${arrows}</svg>`
  const content = layout.nodes
    .map((placed, i) => nodeDiv(placed, contentNodes[i]!, options))
    .join('')
  return `<div class="sb-slide">${svg}<div class="sb-content">${content}</div></div>`
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
  return findPlaced(layout, anchor.name)?.center ?? null
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

function rectSvg(node: PlacedNode): string {
  const x = node.center.x - node.size.width / 2
  const y = SLIDE_H - node.center.y - node.size.height / 2
  return `<rect class="${boxClass(node)}" x="${r(x)}" y="${r(y)}" width="${r(node.size.width)}" height="${r(node.size.height)}"/>`
}

function nodeDiv(node: PlacedNode, source: NodeStatement, options: RenderOptions): string {
  const left = pct(node.center.x - node.size.width / 2, SLIDE_W)
  const top = pct(SLIDE_H - node.center.y - node.size.height / 2, SLIDE_H)
  const width = pct(node.size.width, SLIDE_W)
  // Model identity in the DOM: lets an editor hit-test and address this node
  // (selection, drag, inline edit). Harmless in the export DOM (ADR 0014).
  const id = source.name !== undefined ? ` data-node="${source.name}"` : ''
  return `<div class="${nodeClass(node)}"${id} style="left:${left}%;top:${top}%;width:${width}%">${renderContent(source.content, options)}</div>`
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
    '.sb-box{fill:transparent;stroke:none}',
    '.sb-arrow{fill:none;stroke:#333;stroke-width:0.03}',
    '.sb-style-title{font-weight:bold}',
    '.sb-deferred,.sb-include,.sb-error{opacity:0.7;font-style:italic}',
  ].join('\n')
}

function boxClass(node: PlacedNode): string {
  return ['sb-box', ...node.styleClasses.map((c) => `sb-style-${c}`)].join(' ')
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
