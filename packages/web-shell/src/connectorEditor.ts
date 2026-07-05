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
 *   - two control handles per curved segment (with guide lines): drag for full control;
 *     double-click one to straighten the segment.
 *   - double-click the arrow line to insert a waypoint there.
 */
import {
  findPlaced,
  type Anchor,
  type ConnectorPath,
  type CurveControls,
  type Layout,
  type Point,
} from '@slideblaster/editor'

const SLIDE_W = 16
const SLIDE_H = 9
const SVG_NS = 'http://www.w3.org/2000/svg'

export interface ConnectorEditorActions {
  update(index: number, path: ConnectorPath): void
}

export function paintConnectorEditor(
  overlay: HTMLElement,
  slideEl: HTMLElement,
  index: number,
  source: ConnectorPath,
  layout: Layout,
  actions: ConnectorEditorActions,
): void {
  // Working copy: anchors stay symbolic (node refs preserved); curves hold absolute
  // control points. `pts` are the live drawing positions — node anchors are fixed at the
  // node centre for this paint; a dragged anchor overrides its own entry.
  const anchors: Anchor[] = source.anchors.map(cloneAnchor)
  const curves: (CurveControls | null)[] = source.curves.map(cloneCurve)
  const resolve = (a: Anchor): Point =>
    a.kind === 'node' ? (findPlaced(layout, a.name)?.center ?? { x: 0, y: 0 }) : { ...a.at }
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
    onMove: (p: Point) => void,
    onEnd?: (clientX: number, clientY: number) => void,
  ): void => {
    let active = false
    el.addEventListener('pointerdown', (event) => {
      event.stopPropagation()
      active = true
      el.setPointerCapture(event.pointerId)
    })
    el.addEventListener('pointermove', (event) => {
      if (!active) return
      onMove(toSlide(event.clientX, event.clientY))
      refreshArrow()
    })
    const end = (event: PointerEvent): void => {
      if (!active) return
      active = false
      el.releasePointerCapture(event.pointerId)
      onEnd?.(event.clientX, event.clientY)
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

  // Curve guide lines + control handles (curved segments) or a bend handle (straight).
  for (let j = 0; j < curves.length; j++) {
    const a = pts[j]!
    const b = pts[j + 1]!
    const curve = curves[j]
    if (curve) {
      const l1 = seg(a, curve.c1, 'sb-ctrl-line')
      const l2 = seg(b, curve.c2, 'sb-ctrl-line')
      const h1 = dot(curve.c1, 'sb-ctrl', 0.12)
      draggable(h1, (p) => {
        curve.c1 = p
        move(h1, p)
        l1.setAttribute('x2', String(p.x))
        l1.setAttribute('y2', String(flip(p.y)))
      })
      const h2 = dot(curve.c2, 'sb-ctrl', 0.12)
      draggable(h2, (p) => {
        curve.c2 = p
        move(h2, p)
        l2.setAttribute('x2', String(p.x))
        l2.setAttribute('y2', String(flip(p.y)))
      })
      const straighten = (event: Event): void => {
        event.stopPropagation()
        curves[j] = null
        commit()
      }
      h1.addEventListener('dblclick', straighten)
      h2.addEventListener('dblclick', straighten)
    } else {
      const mid = { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 }
      const bend = dot(mid, 'sb-bend', 0.12)
      draggable(bend, (p) => {
        curves[j] = bendControls(pts[j]!, pts[j + 1]!, p)
        move(bend, p)
      })
    }
  }

  // Anchor handles last (on top). Interior ones delete on double-click.
  for (let i = 0; i < pts.length; i++) {
    const handle = dot(pts[i]!, 'sb-anchor')
    draggable(
      handle,
      (p) => {
        pts[i] = p
        move(handle, p)
      },
      (clientX, clientY) => reattach(i, clientX, clientY),
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

  // On dropping an anchor, re-attach to the node under the pointer, else a free point.
  function reattach(i: number, clientX: number, clientY: number): void {
    svg.style.display = 'none' // reveal the node beneath the handle for hit-testing
    const target = document.elementFromPoint(clientX, clientY)
    svg.style.display = ''
    const node = target instanceof Element ? target.closest<HTMLElement>('.sb-handle') : null
    const name = node?.dataset.node
    anchors[i] = name ? { kind: 'node', name } : { kind: 'point', at: { ...pts[i]! } }
  }
}

function cloneAnchor(a: Anchor): Anchor {
  return a.kind === 'node' ? { kind: 'node', name: a.name } : { kind: 'point', at: { ...a.at } }
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
