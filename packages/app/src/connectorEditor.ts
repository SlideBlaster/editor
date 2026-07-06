/**
 * Reshape a selected connector on the canvas. Contract: see connectorEditor.md.
 *
 * Draws editing handles over a selected arrow's `ConnectorPath` (from the engine's
 * `connectorsOf(...).editable`) and turns drags into a reshaped path committed via
 * `actions.update` (E4+, updateConnector). During a drag the arrow's own `<path>` and the
 * dragged handle are updated *in place* (never rebuilt) so pointer capture holds; the
 * commit triggers a re-render that rebuilds the handles fresh.
 *
 * Handles:
 *   - anchor dots at every anchor: drag to move; drop on a node re-attaches (`(name)`),
 *     else it becomes a free point `(x,y)`. Double-click an interior anchor to delete it.
 *   - a bend handle at each straight segment's midpoint: drag to curve it (cubic).
 *   - two control handles per curved segment (with guide lines): drag for full control
 *     (control arms soft-snap to 15°, Alt to override); double-click one to straighten.
 *   - double-click the arrow line to insert a waypoint there.
 *
 * It also reports one anchor (dot) to the controller via `actions.focusCurve` (on paint, and
 * when a dot/handle is grabbed), so the properties panel can edit the tangent angle(s) *at
 * that point*; `focusedAnchor` says which dot the panel is currently editing (for the
 * highlight). Clicking a dark-blue split point focuses that point.
 */
import {
  anchor as nodeAnchorPoint,
  findPlaced,
  isAnchorName,
  type Anchor,
  type AnchorName,
  type ConnectorPath,
  type CurveControls,
  type Layout,
  type PlacedNode,
  type Point,
} from '@slideblaster/editor'

const SLIDE_W = 16
const SLIDE_H = 9
const SVG_NS = 'http://www.w3.org/2000/svg'

export interface ConnectorEditorActions {
  update(index: number, path: ConnectorPath): void
  /** Focus an anchor (a dot — endpoint or split-point waypoint) for angle editing in the
   *  properties panel (null clears). Fires on paint (so the panel tracks the live geometry)
   *  and when a dot/handle is grabbed. Carries the resolved neighbourhood + the working path
   *  so the panel can show/set the tangent angle(s) *at that point*. */
  focusCurve(focus: CurveFocus | null): void
}

/** An anchor (dot) surfaced for angle editing: its resolved position `point`, its resolved
 *  neighbours (`prevPoint`/`nextPoint`, null at an end — these bound the arriving/leaving
 *  segments), and the full working path (symbolic anchors preserved) to rebuild from. The
 *  panel reads the control arms that meet at `point`: c2 of the incoming segment (`anchor-1`)
 *  and c1 of the outgoing one (`anchor`). */
export interface CurveFocus {
  index: number
  anchor: number
  point: Point
  prevPoint: Point | null
  nextPoint: Point | null
  path: ConnectorPath
}

export function paintConnectorEditor(
  overlay: HTMLElement,
  slideEl: HTMLElement,
  index: number,
  source: ConnectorPath,
  layout: Layout,
  actions: ConnectorEditorActions,
  focusedAnchor: number | null = null,
): void {
  // Working copy: anchors stay symbolic (node refs preserved); curves hold absolute
  // control points. `pts` are the live drawing positions — node anchors are fixed at the
  // node centre for this paint; a dragged anchor overrides its own entry.
  const anchors: Anchor[] = source.anchors.map(cloneAnchor)
  const curves: (CurveControls | null)[] = source.curves.map(cloneCurve)
  const resolve = (a: Anchor): Point => {
    if (a.kind === 'point') return { ...a.at }
    const placed = findPlaced(layout, a.name)
    if (!placed) return { x: 0, y: 0 }
    return a.anchor && isAnchorName(a.anchor) ? nodeAnchorPoint(placed, a.anchor) : placed.center
  }
  const pts: Point[] = anchors.map(resolve)

  const arrow = slideEl.querySelector<SVGPathElement>(`.sb-arrow[data-arrow="${index}"]`)
  const flip = (y: number): number => SLIDE_H - y
  const toSlide = (clientX: number, clientY: number): Point => {
    const rect = slideEl.getBoundingClientRect()
    return {
      x: ((clientX - rect.left) / rect.width) * SLIDE_W,
      y: SLIDE_H - ((clientY - rect.top) / rect.height) * SLIDE_H,
    }
  }
  const pathData = (): string => {
    let d = `M ${pts[0]!.x},${flip(pts[0]!.y)}`
    for (let i = 1; i < pts.length; i++) {
      const c = curves[i - 1]
      d += c
        ? ` C ${c.c1.x},${flip(c.c1.y)} ${c.c2.x},${flip(c.c2.y)} ${pts[i]!.x},${flip(pts[i]!.y)}`
        : ` L ${pts[i]!.x},${flip(pts[i]!.y)}`
    }
    return d
  }
  const refreshArrow = (): void => arrow?.setAttribute('d', pathData())
  const commit = (): void =>
    actions.update(index, { anchors: anchors.map(cloneAnchor), curves: curves.map(cloneCurve) })

  const svg = document.createElementNS(SVG_NS, 'svg')
  svg.setAttribute('class', 'sb-conn-edit')
  svg.setAttribute('viewBox', `0 0 ${SLIDE_W} ${SLIDE_H}`)
  svg.setAttribute('preserveAspectRatio', 'none')
  overlay.append(svg)

  const move = (el: SVGElement, p: Point): void => {
    el.setAttribute('cx', String(p.x))
    el.setAttribute('cy', String(flip(p.y)))
  }
  const dot = (p: Point, cls: string, r = 0.14): SVGCircleElement => {
    const el = document.createElementNS(SVG_NS, 'circle')
    move(el, p)
    el.setAttribute('r', String(r))
    el.setAttribute('class', cls)
    svg.append(el)
    return el
  }
  const seg = (a: Point, b: Point, cls: string): SVGLineElement => {
    const el = document.createElementNS(SVG_NS, 'line')
    el.setAttribute('x1', String(a.x))
    el.setAttribute('y1', String(flip(a.y)))
    el.setAttribute('x2', String(b.x))
    el.setAttribute('y2', String(flip(b.y)))
    el.setAttribute('class', cls)
    svg.append(el)
    return el
  }

  // A handle drag: `onMove` mutates the model + updates elements in place; on release
  // it commits (which re-renders and rebuilds the handles). No rebuild mid-drag.
  const draggable = (
    el: SVGElement,
    onMove: (p: Point, event: PointerEvent) => void,
    hooks: { onStart?: () => void; onEnd?: () => void } = {},
  ): void => {
    let active = false
    el.addEventListener('pointerdown', (event) => {
      event.stopPropagation()
      active = true
      el.setPointerCapture(event.pointerId)
      hooks.onStart?.()
    })
    el.addEventListener('pointermove', (event) => {
      if (!active) return
      onMove(toSlide(event.clientX, event.clientY), event)
      refreshArrow()
    })
    const end = (event: PointerEvent): void => {
      if (!active) return
      active = false
      el.releasePointerCapture(event.pointerId)
      hooks.onEnd?.()
      commit()
    }
    el.addEventListener('pointerup', end)
    el.addEventListener('pointercancel', end)
  }

  // Double-click the arrow line to insert a waypoint (a structural change -> commit).
  const addLine = document.createElementNS(SVG_NS, 'path')
  addLine.setAttribute('d', pathData())
  addLine.setAttribute('class', 'sb-conn-add')
  addLine.addEventListener('dblclick', (event) => {
    event.stopPropagation()
    const p = toSlide(event.clientX, event.clientY)
    const j = nearestSegment(p, pts)
    anchors.splice(j + 1, 0, { kind: 'point', at: { ...p } })
    curves.splice(j, 1, null, null)
    commit()
  })
  svg.append(addLine)

  // A snapshot of the anchor `i`'s neighbourhood the panel edits its tangent angle(s)
  // against (symbolic anchors preserved so node attachments survive an angle edit).
  const anchorPayload = (i: number): CurveFocus => ({
    index,
    anchor: i,
    point: { ...pts[i]! },
    prevPoint: i > 0 ? { ...pts[i - 1]! } : null,
    nextPoint: i < pts.length - 1 ? { ...pts[i + 1]! } : null,
    path: { anchors: anchors.map(cloneAnchor), curves: curves.map(cloneCurve) },
  })
  // Which anchor (dot) the panel edits: the requested one (if in range), else the first
  // split-point waypoint, else the start. So selecting *any* editable arrow lights up its
  // angles, and clicking a dark-blue split point focuses *that* point.
  const effective =
    focusedAnchor !== null && focusedAnchor >= 0 && focusedAnchor < pts.length
      ? focusedAnchor
      : pts.length > 2
        ? 1
        : 0

  // Curve guide lines + control handles (curved segments) or a bend handle (straight). A
  // control handle focuses the anchor its arm grows from (c1 -> start, c2 -> end).
  for (let j = 0; j < curves.length; j++) {
    const a = pts[j]!
    const b = pts[j + 1]!
    const curve = curves[j]
    if (curve) {
      const on1 = j === effective ? ' is-focused' : ''
      const on2 = j + 1 === effective ? ' is-focused' : ''
      const l1 = seg(a, curve.c1, 'sb-ctrl-line' + on1)
      const l2 = seg(b, curve.c2, 'sb-ctrl-line' + on2)
      const h1 = dot(curve.c1, 'sb-ctrl' + on1, 0.12)
      draggable(
        h1,
        (p, event) => {
          const q = snapArm(a, p, event.altKey)
          curve.c1 = q
          move(h1, q)
          l1.setAttribute('x2', String(q.x))
          l1.setAttribute('y2', String(flip(q.y)))
        },
        { onStart: () => actions.focusCurve(anchorPayload(j)) },
      )
      const h2 = dot(curve.c2, 'sb-ctrl' + on2, 0.12)
      draggable(
        h2,
        (p, event) => {
          const q = snapArm(b, p, event.altKey)
          curve.c2 = q
          move(h2, q)
          l2.setAttribute('x2', String(q.x))
          l2.setAttribute('y2', String(flip(q.y)))
        },
        { onStart: () => actions.focusCurve(anchorPayload(j + 1)) },
      )
      const straighten = (event: Event): void => {
        event.stopPropagation()
        curves[j] = null
        commit()
      }
      h1.addEventListener('dblclick', straighten)
      h2.addEventListener('dblclick', straighten)
    } else {
      const mid = { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 }
      const near = effective === j || effective === j + 1 // either end of this straight segment
      const bend = dot(mid, near ? 'sb-bend is-focused' : 'sb-bend', 0.12)
      draggable(
        bend,
        (p) => {
          curves[j] = bendControls(pts[j]!, pts[j + 1]!, p)
          move(bend, p)
        },
        { onStart: () => actions.focusCurve(anchorPayload(j)) },
      )
    }
  }

  // Snap layer: while an anchor is dragged, a dot marks every border anchor (N/S/E/W, the
  // corners, and the centre) of every node it can attach to; the one being snapped is
  // highlighted. Dots are indicators only (pointer-events none).
  const snapLayer = document.createElementNS(SVG_NS, 'g')
  snapLayer.setAttribute('class', 'sb-snap-layer')
  svg.append(snapLayer)
  let snapped: { name: string; port: AnchorName } | null = null
  const showSnapDots = (): void => {
    snapLayer.replaceChildren()
    for (const node of layout.nodes) {
      if (!node.name) continue
      for (const port of PORTS) {
        const pt = nodeAnchorPoint(node, port)
        const d = document.createElementNS(SVG_NS, 'circle')
        d.setAttribute('cx', String(pt.x))
        d.setAttribute('cy', String(flip(pt.y)))
        d.setAttribute('r', port === 'center' ? '0.1' : '0.08')
        d.setAttribute('class', 'sb-snap-dot')
        d.dataset.key = snapKey(node.name, port)
        snapLayer.append(d)
      }
    }
  }
  const highlightSnap = (key: string | null): void => {
    for (const child of Array.from(snapLayer.children)) {
      child.classList.toggle('is-active', (child as SVGElement).dataset.key === key)
    }
  }

  // Anchor handles last (on top). Drag snaps to the nearest border anchor of whatever node
  // the pointer is over; on release it attaches there (`(name.north)`, or `(name)` for the
  // centre), else it becomes a free point. Interior anchors delete on double-click.
  for (let i = 0; i < pts.length; i++) {
    // Grabbing a dot focuses that anchor, so its tangent angle(s) show in the panel.
    const handle = dot(pts[i]!, i === effective ? 'sb-anchor is-focused' : 'sb-anchor')
    draggable(
      handle,
      (p) => {
        const snap = nearestAnchor(p, layout.nodes)
        snapped = snap ? { name: snap.name, port: snap.port } : null
        const pos = snap ? snap.point : p
        pts[i] = pos
        move(handle, pos)
        highlightSnap(snap ? snapKey(snap.name, snap.port) : null)
      },
      {
        onStart: () => {
          snapped = null
          actions.focusCurve(anchorPayload(i))
          showSnapDots()
        },
        onEnd: () => {
          anchors[i] = snapped
            ? snapped.port === 'center'
              ? { kind: 'node', name: snapped.name }
              : { kind: 'node', name: snapped.name, anchor: snapped.port }
            : { kind: 'point', at: { ...pts[i]! } }
          snapLayer.replaceChildren()
        },
      },
    )
    if (i > 0 && i < pts.length - 1) {
      handle.classList.add('is-waypoint')
      handle.addEventListener('dblclick', (event) => {
        event.stopPropagation()
        anchors.splice(i, 1)
        curves.splice(i - 1, 2, null)
        commit()
      })
    }
  }

  // Publish the focused anchor's live neighbourhood to the panel. Runs after every paint, so
  // an angle edit / node move / re-split refreshes what the angle fields edit against.
  actions.focusCurve(anchorPayload(effective))
}

const ANGLE_STEP = Math.PI / 12 // snap control arms to 15° increments…
const ANGLE_TOL = (2.5 * Math.PI) / 180 // …but only within 2.5°, so most of the drag is free

/** Snap a control point so its arm out of `anchor` lands on a 15° increment when the drag
 *  is already close to one (Alt bypasses). The arm length is kept; only the angle clicks. */
function snapArm(anchor: Point, p: Point, free: boolean): Point {
  if (free) return p
  const dx = p.x - anchor.x
  const dy = p.y - anchor.y
  const len = Math.hypot(dx, dy)
  if (len < 1e-4) return p
  const angle = Math.atan2(dy, dx)
  const snapped = Math.round(angle / ANGLE_STEP) * ANGLE_STEP
  let diff = angle - snapped
  while (diff > Math.PI) diff -= 2 * Math.PI
  while (diff < -Math.PI) diff += 2 * Math.PI
  if (Math.abs(diff) > ANGLE_TOL) return p
  return { x: anchor.x + len * Math.cos(snapped), y: anchor.y + len * Math.sin(snapped) }
}

/** The node border anchors an endpoint can snap to, in preference order (the centre last
 *  so it loses ties to an edge — arrows read better touching a border than buried inside). */
const PORTS: readonly AnchorName[] = [
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
function snapKey(name: string, port: AnchorName): string {
  return `${name}|${port}`
}

/** The border anchor to snap a dragged endpoint to: pick the node whose box (with a small
 *  margin) contains `p` (nearest centre wins), then that node's anchor nearest to `p`. Null
 *  when the pointer is over no node — the endpoint stays a free point. */
function nearestAnchor(
  p: Point,
  nodes: readonly PlacedNode[],
): { name: string; port: AnchorName; point: Point } | null {
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
  if (!node?.name) return null
  let best: { name: string; port: AnchorName; point: Point } | null = null
  let bestD = Infinity
  for (const port of PORTS) {
    const point = nodeAnchorPoint(node, port)
    const d = Math.hypot(p.x - point.x, p.y - point.y)
    if (d < bestD) {
      bestD = d
      best = { name: node.name, port, point }
    }
  }
  return best
}

function cloneAnchor(a: Anchor): Anchor {
  if (a.kind === 'point') return { kind: 'point', at: { ...a.at } }
  return a.anchor
    ? { kind: 'node', name: a.name, anchor: a.anchor }
    : { kind: 'node', name: a.name }
}

function cloneCurve(c: CurveControls | null): CurveControls | null {
  return c ? { c1: { ...c.c1 }, c2: { ...c.c2 } } : null
}

/** Cubic controls that bow the segment a->b through the dragged point `m` at t=0.5. */
function bendControls(a: Point, b: Point, m: Point): CurveControls {
  const mid = { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 }
  const off = { x: (m.x - mid.x) * (4 / 3), y: (m.y - mid.y) * (4 / 3) }
  const lerp = (t: number): Point => ({
    x: a.x + (b.x - a.x) * t + off.x,
    y: a.y + (b.y - a.y) * t + off.y,
  })
  return { c1: lerp(1 / 3), c2: lerp(2 / 3) }
}

/** Index of the segment (pts[j]..pts[j+1]) nearest to `p`. */
function nearestSegment(p: Point, pts: Point[]): number {
  let best = 0
  let bestD = Infinity
  for (let j = 0; j < pts.length - 1; j++) {
    const d = distToSegment(p, pts[j]!, pts[j + 1]!)
    if (d < bestD) {
      bestD = d
      best = j
    }
  }
  return best
}

function distToSegment(p: Point, a: Point, b: Point): number {
  const dx = b.x - a.x
  const dy = b.y - a.y
  const len2 = dx * dx + dy * dy
  const t = len2 === 0 ? 0 : Math.max(0, Math.min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
  return Math.hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
}
