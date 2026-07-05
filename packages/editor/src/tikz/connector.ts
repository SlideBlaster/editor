/**
 * Structured view of a connector's path body. Contract: see connector.md.
 *
 * A `\draw` body is verbatim in the model (tikz.ts); this parses the editable subset —
 * anchors (a node `(name)` or a coordinate `(x,y)`) joined by either a straight segment
 * (`--`) or a cubic Bézier (`.. controls (c1) and (c2) ..`) — into a `ConnectorPath` the
 * editor can reshape, and serializes it back. Tolerant: a body outside this subset
 * (orthogonal `-|`, `to[...]`, loops, …) yields `null` and stays verbatim, non-editable.
 * Control points are absolute coordinates, matching TikZ — the full-control curve surface.
 */
import type { Point } from '../model/tikz'
import { formatNumber } from '../text/scanner'

export interface AnchorNode {
  kind: 'node'
  name: string
  /** An optional border anchor of the node (TikZ `(name.north)`) — `north`, `south east`,
   *  etc. Absent means the node's default anchor (its centre). */
  anchor?: string
}
export interface AnchorPoint {
  kind: 'point'
  at: Point
}
export type Anchor = AnchorNode | AnchorPoint

/** The two cubic control points of a curved segment (absolute slide-space). */
export interface CurveControls {
  c1: Point
  c2: Point
}

/**
 * An editable connector: `anchors` (>= 2) joined by segments. `curves[i]` describes the
 * segment from `anchors[i]` to `anchors[i+1]` — `null` for a straight `--`, otherwise a
 * cubic. `curves.length === anchors.length - 1`.
 */
export interface ConnectorPath {
  anchors: Anchor[]
  curves: (CurveControls | null)[]
}

function toAnchor(inner: string): Anchor {
  const trimmed = inner.trim()
  const point = /^(-?[\d.]+)\s*,\s*(-?[\d.]+)$/.exec(trimmed)
  if (point) return { kind: 'point', at: { x: Number(point[1]), y: Number(point[2]) } }
  // `name.anchor` (e.g. `box.north east`): the dot splits the node id from its border anchor.
  const dot = trimmed.indexOf('.')
  if (dot > 0)
    return { kind: 'node', name: trimmed.slice(0, dot), anchor: trimmed.slice(dot + 1).trim() }
  return { kind: 'node', name: trimmed }
}

export function parseConnector(body: string): ConnectorPath | null {
  let rest = body
  const anchors: Anchor[] = []
  const curves: (CurveControls | null)[] = []

  const readAnchor = (): Anchor | null => {
    const m = /^\s*\(\s*([^()]*?)\s*\)/.exec(rest)
    if (!m) return null
    rest = rest.slice(m[0].length)
    return toAnchor(m[1]!)
  }
  const readPoint = (): Point | null => {
    const m = /^\s*\(\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)\s*\)/.exec(rest)
    if (!m) return null
    rest = rest.slice(m[0].length)
    return { x: Number(m[1]), y: Number(m[2]) }
  }

  const first = readAnchor()
  if (!first) return null
  anchors.push(first)

  while (rest.trim().length > 0) {
    const straight = /^\s*--/.exec(rest)
    if (straight) {
      rest = rest.slice(straight[0].length)
      const next = readAnchor()
      if (!next) return null
      anchors.push(next)
      curves.push(null)
      continue
    }
    const curveOpen = /^\s*\.\.\s*controls/.exec(rest)
    if (curveOpen) {
      rest = rest.slice(curveOpen[0].length)
      const c1 = readPoint()
      if (!c1) return null
      const and = /^\s*and\b/.exec(rest)
      if (!and) return null
      rest = rest.slice(and[0].length)
      const c2 = readPoint()
      if (!c2) return null
      const curveClose = /^\s*\.\./.exec(rest)
      if (!curveClose) return null
      rest = rest.slice(curveClose[0].length)
      const next = readAnchor()
      if (!next) return null
      anchors.push(next)
      curves.push({ c1, c2 })
      continue
    }
    return null // an unrecognized token — not in the editable subset
  }

  return anchors.length >= 2 ? { anchors, curves } : null
}

function anchorText(anchor: Anchor): string {
  return anchor.kind === 'node'
    ? `(${anchor.name}${anchor.anchor ? `.${anchor.anchor}` : ''})`
    : `(${formatNumber(anchor.at.x)},${formatNumber(anchor.at.y)})`
}

function pointText(p: Point): string {
  return `(${formatNumber(p.x)},${formatNumber(p.y)})`
}

/** Serialize back to a path body with a leading space (the body convention in tikz.ts). */
export function serializeConnector(path: ConnectorPath): string {
  let out = ` ${anchorText(path.anchors[0]!)}`
  for (let i = 0; i < path.curves.length; i++) {
    const curve = path.curves[i]!
    const next = anchorText(path.anchors[i + 1]!)
    out += curve
      ? ` .. controls ${pointText(curve.c1)} and ${pointText(curve.c2)} .. ${next}`
      : ` -- ${next}`
  }
  return out
}
