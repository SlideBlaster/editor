/**
 * Shared anchor-port snapping for connectors — used by both the reshape editor
 * (connectorEditor.ts) and the connect-mode create gesture (canvas.ts), so an arrow is
 * drawn and reshaped against the *same* anchor-point view.
 *
 * A connector endpoint attaches either to one of a node's border anchors — N/S/E/W, the four
 * corners, or the centre (TikZ `(name.north)` / `(name)`) — or lands in free space as a bare
 * coordinate `(x,y)`. `nearestAnchor` snaps a point to the nearest border anchor of whatever
 * node the pointer is over (null when over none — a free point); `paintSnapDots` /
 * `setActiveSnaps` draw the dots both surfaces show while a drag is in flight.
 */
import {
  anchor as nodeAnchorPoint,
  type Anchor,
  type AnchorName,
  type PlacedNode,
  type Point,
} from '@slideblaster/editor'

const SLIDE_H = 9
const SVG_NS = 'http://www.w3.org/2000/svg'

/** A resolved snap: the node's `name`, the border `port`, and that port's slide-space `point`. */
export interface Snap {
  name: string
  port: AnchorName
  point: Point
}

/** The border anchors an endpoint can snap to, in preference order (the centre last so it
 *  loses ties to an edge — arrows read better touching a border than buried inside). */
export const PORTS: readonly AnchorName[] = [
  'north',
  'south',
  'east',
  'west',
  'north east',
  'north west',
  'south east',
  'south west',
  'center',
]

/** Stable id for a node's border-anchor dot (`name|port`), so a drag can highlight it. */
export function snapKey(name: string, port: AnchorName): string {
  return `${name}|${port}`
}

/** The border anchor to snap a dragged endpoint to: pick the node whose box (with a small
 *  margin) contains `p` (nearest centre wins), then that node's anchor nearest to `p`. Null
 *  when the pointer is over no node — the endpoint stays a free point. */
export function nearestAnchor(p: Point, nodes: readonly PlacedNode[]): Snap | null {
  const MARGIN = 0.3
  let node: PlacedNode | null = null
  let nodeD = Infinity
  for (const n of nodes) {
    if (!n.name) continue
    const hw = n.size.width / 2 + MARGIN
    const hh = n.size.height / 2 + MARGIN
    if (Math.abs(p.x - n.center.x) <= hw && Math.abs(p.y - n.center.y) <= hh) {
      const d = Math.hypot(p.x - n.center.x, p.y - n.center.y)
      if (d < nodeD) {
        nodeD = d
        node = n
      }
    }
  }
  return node ? nearestAnchorOn(p, node) : null
}

/** The border anchor of `node` nearest to `p` — never null (the source you pressed on always
 *  resolves to one of its ports). */
export function nearestAnchorOn(p: Point, node: PlacedNode): Snap {
  let best: Snap | null = null
  let bestD = Infinity
  for (const port of PORTS) {
    const point = nodeAnchorPoint(node, port)
    const d = Math.hypot(p.x - point.x, p.y - point.y)
    if (d < bestD) {
      bestD = d
      best = { name: node.name!, port, point }
    }
  }
  return best!
}

/** The engine `Anchor` for a snap: the centre drops the suffix (the node's default anchor). */
export function snapToAnchor(s: Snap): Anchor {
  return s.port === 'center'
    ? { kind: 'node', name: s.name }
    : { kind: 'node', name: s.name, anchor: s.port }
}

/** Paint the anchor-point view into `layer` (an SVG element in slide coords, y flipped to the
 *  viewBox): a dot at every border anchor of every named node. Indicators only — the caller's
 *  CSS gives `.sb-snap-dot` `pointer-events: none`. */
export function paintSnapDots(layer: SVGElement, nodes: readonly PlacedNode[]): void {
  layer.replaceChildren()
  for (const node of nodes) {
    if (!node.name) continue
    for (const port of PORTS) {
      const pt = nodeAnchorPoint(node, port)
      const d = document.createElementNS(SVG_NS, 'circle')
      d.setAttribute('cx', String(pt.x))
      d.setAttribute('cy', String(SLIDE_H - pt.y))
      d.setAttribute('r', port === 'center' ? '0.1' : '0.08')
      d.setAttribute('class', 'sb-snap-dot')
      d.dataset.key = snapKey(node.name, port)
      layer.append(d)
    }
  }
}

/** Solid-highlight the dots whose keys are in `keys` (the ports the drag is snapping to). */
export function setActiveSnaps(layer: SVGElement, keys: readonly string[]): void {
  for (const child of Array.from(layer.children)) {
    const k = (child as SVGElement).dataset.key
    child.classList.toggle('is-active', k !== undefined && keys.includes(k))
  }
}
