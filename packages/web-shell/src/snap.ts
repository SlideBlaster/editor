/**
 * Drag snapping: a pure geometry resolver. Contract: see snap.md.
 *
 * Given a dragged node's proposed box and its peers on the same slide, nudge the
 * proposed center onto a meaningful alignment and report the guide lines to draw.
 * Each axis (x, y) resolves independently with a fixed precedence:
 *   1. alignment  — the dragged node's left/center/right (or top/center/bottom)
 *                   meets a peer's edge/center or a slide guide (center, thirds, edges)
 *   2. spacing    — the dragged node centers in an equal gap between two flanking
 *                   peers that overlap it on the other axis
 *   3. grid       — the dragged node's center falls on the sub-unit grid
 * All distances are in slide units (0..16 x 0..9, y-up), so the caller converts a
 * pixel snap radius to units once (zoom-independent feel). This module is UI-free
 * and fully testable; canvas.ts maps its result back to a pixel preview + commit.
 * It never chooses absolute-vs-relative placement — that is the E2 relative-binding
 * drop, deferred (ux/positioning-snapping.md).
 */
import type { Point } from '@slideblaster/editor'

export interface SnapSize {
  width: number
  height: number
}

/** A node box in slide space: its center and full extent. */
export interface SnapBox {
  center: Point
  size: SnapSize
}

export interface SnapConfig {
  /** Snap radius in slide units: a reference point within this distance engages. */
  threshold: number
  /** Sub-unit grid step in slide units; 0 disables grid snapping. */
  grid: number
  slideWidth: number
  slideHeight: number
}

/** A guide segment to draw, in slide space (y-up). `align` spans a full edge/center
 *  line; `space` marks one of the two equal gaps of a spacing snap. */
export interface SnapLine {
  x1: number
  y1: number
  x2: number
  y2: number
  kind: 'align' | 'space'
}

export interface SnapResult {
  center: Point
  guides: SnapLine[]
}

/** One axis projected to scalars: `c`/`half` along the axis, `pc`/`phalf` across it. */
interface AxisBox {
  c: number
  half: number
  pc: number
  phalf: number
}

/** Resolve one axis. Returns the snapped along-axis center and, when a peer/slide
 *  alignment engages, the coordinate of its guide line (`guideAt`). */
function alignAxis(
  dragged: AxisBox,
  refs: readonly number[],
  threshold: number,
): { center: number; guideAt: number } | null {
  const points = [dragged.c - dragged.half, dragged.c, dragged.c + dragged.half]
  let best: { d: number; center: number; guideAt: number } | null = null
  for (const target of refs) {
    for (const rp of points) {
      const d = Math.abs(target - rp)
      if (d <= threshold && (best === null || d < best.d)) {
        best = { d, center: dragged.c + (target - rp), guideAt: target }
      }
    }
  }
  return best === null ? null : { center: best.center, guideAt: best.guideAt }
}

/** Equal-spacing snap: center the dragged node in the gap between its nearest peers
 *  on each side that overlap it on the other axis. Returns the snapped center and the
 *  inner edges of the two flankers (for drawing the two equal gaps). */
function spacingAxis(
  dragged: AxisBox,
  peers: readonly AxisBox[],
  threshold: number,
): { center: number; leftEdge: number; rightEdge: number } | null {
  let leftEdge = -Infinity // nearest flanker on the low side: its high edge
  let rightEdge = Infinity // nearest flanker on the high side: its low edge
  for (const peer of peers) {
    const overlaps = Math.abs(dragged.pc - peer.pc) < dragged.phalf + peer.phalf
    if (!overlaps) continue
    const peerHigh = peer.c + peer.half
    const peerLow = peer.c - peer.half
    if (peerHigh <= dragged.c && peerHigh > leftEdge) leftEdge = peerHigh
    if (peerLow >= dragged.c && peerLow < rightEdge) rightEdge = peerLow
  }
  if (leftEdge === -Infinity || rightEdge === Infinity) return null
  const center = (leftEdge + rightEdge) / 2 // equal gap: independent of the node's size
  if (Math.abs(center - dragged.c) > threshold) return null
  return { center, leftEdge, rightEdge }
}

/** Snap the dragged center to the nearest grid multiple, if within threshold. */
function gridAxis(c: number, grid: number, threshold: number): number | null {
  if (grid <= 0) return null
  const snapped = Math.round(c / grid) * grid
  return Math.abs(snapped - c) <= threshold ? snapped : null
}

/** Slide guide lines along an axis: edges, center, and thirds. */
function slideGuides(extent: number): number[] {
  return [0, extent / 3, extent / 2, (2 * extent) / 3, extent]
}

export function resolveSnap(
  dragged: SnapBox,
  peers: readonly SnapBox[],
  config: SnapConfig,
): SnapResult {
  const { threshold, grid, slideWidth, slideHeight } = config
  const guides: SnapLine[] = []

  const project = (box: SnapBox, axis: 'x' | 'y'): AxisBox =>
    axis === 'x'
      ? { c: box.center.x, half: box.size.width / 2, pc: box.center.y, phalf: box.size.height / 2 }
      : { c: box.center.y, half: box.size.height / 2, pc: box.center.x, phalf: box.size.width / 2 }

  const resolveAxis = (axis: 'x' | 'y', extent: number, perpExtent: number): number => {
    const self = project(dragged, axis)
    const peerBoxes = peers.map((p) => project(p, axis))
    const refs = [
      ...slideGuides(extent),
      ...peerBoxes.flatMap((p) => [p.c - p.half, p.c, p.c + p.half]),
    ]

    const aligned = alignAxis(self, refs, threshold)
    if (aligned) {
      // A full-span guide line at the alignment coordinate (perpendicular to the axis).
      if (axis === 'x')
        guides.push({
          x1: aligned.guideAt,
          y1: 0,
          x2: aligned.guideAt,
          y2: perpExtent,
          kind: 'align',
        })
      else
        guides.push({
          x1: 0,
          y1: aligned.guideAt,
          x2: perpExtent,
          y2: aligned.guideAt,
          kind: 'align',
        })
      return aligned.center
    }

    const spaced = spacingAxis(self, peerBoxes, threshold)
    if (spaced) {
      // Two equal-gap segments at the dragged node's perpendicular center.
      const half = self.half
      const perp = self.pc
      const near = spaced.center - half
      const far = spaced.center + half
      if (axis === 'x') {
        guides.push({ x1: spaced.leftEdge, y1: perp, x2: near, y2: perp, kind: 'space' })
        guides.push({ x1: far, y1: perp, x2: spaced.rightEdge, y2: perp, kind: 'space' })
      } else {
        guides.push({ x1: perp, y1: spaced.leftEdge, x2: perp, y2: near, kind: 'space' })
        guides.push({ x1: perp, y1: far, x2: perp, y2: spaced.rightEdge, kind: 'space' })
      }
      return spaced.center
    }

    const gridded = gridAxis(self.c, grid, threshold)
    return gridded ?? self.c
  }

  const x = resolveAxis('x', slideWidth, slideHeight)
  const y = resolveAxis('y', slideHeight, slideWidth)
  return { center: { x, y }, guides }
}
