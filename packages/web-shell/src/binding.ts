/**
 * Relative-binding detection for a drag (E2). Contract: see binding.md.
 *
 * The counterpart to [snap.ts](./snap.md): where snapping resolves an *absolute* drop,
 * this decides whether the dragged node should instead **bind** to a peer —
 * `[below=<gap> of ref]`. A binding is offered when the node sits just off one side of
 * a peer and is aligned with it on the other axis (so it reads as "below img", not
 * floating diagonally). The gap is seeded from the drop distance. Pure and testable;
 * canvas.ts prefers a binding over an absolute snap, and falls back to absolute (i.e.
 * detaches) when no binding is in range. The resolved `center` mirrors the engine's
 * `relativeCenter`, so the drag preview lands exactly where `placeNodeRelative` renders.
 */
import type { Point } from '@slideblaster/editor'
import type { SnapSize } from './snap'

export type BindSide = 'above' | 'below' | 'left' | 'right'

/** A named peer box — binding needs the ref name that snapping doesn't. */
export interface BindBox {
  name: string
  center: Point
  size: SnapSize
}

export interface BindConfig {
  /** Max misalignment on the perpendicular axis to still read as "on that side". */
  alignTol: number
  /** Max edge-to-edge gap that still reads as attached (pull past this to detach). */
  maxGap: number
}

export interface Binding {
  ref: string
  side: BindSide
  gap: number
  /** Resolved center for the preview — matches the engine's relativeCenter. */
  center: Point
}

/** Center of a node placed `side` of `peer` with edge-to-edge `gap` (mirrors the
 *  engine's layout/resolve.relativeCenter, y-up). */
function bindCenter(peer: BindBox, size: SnapSize, side: BindSide, gap: number): Point {
  const phw = peer.size.width / 2
  const phh = peer.size.height / 2
  const hw = size.width / 2
  const hh = size.height / 2
  switch (side) {
    case 'below':
      return { x: peer.center.x, y: peer.center.y - phh - gap - hh }
    case 'above':
      return { x: peer.center.x, y: peer.center.y + phh + gap + hh }
    case 'left':
      return { x: peer.center.x - phw - gap - hw, y: peer.center.y }
    case 'right':
      return { x: peer.center.x + phw + gap + hw, y: peer.center.y }
  }
}

export function findBinding(
  dragged: { center: Point; size: SnapSize },
  peers: readonly BindBox[],
  config: BindConfig,
): Binding | null {
  const dhw = dragged.size.width / 2
  const dhh = dragged.size.height / 2
  let best: (Binding & { score: number }) | null = null

  for (const peer of peers) {
    const phw = peer.size.width / 2
    const phh = peer.size.height / 2
    const dx = Math.abs(dragged.center.x - peer.center.x) // x-misalignment (for above/below)
    const dy = Math.abs(dragged.center.y - peer.center.y) // y-misalignment (for left/right)
    // Each candidate: perpendicular misalignment + the edge-to-edge gap on that side.
    const cases: { side: BindSide; align: number; rawGap: number }[] = [
      { side: 'below', align: dx, rawGap: peer.center.y - phh - (dragged.center.y + dhh) },
      { side: 'above', align: dx, rawGap: dragged.center.y - dhh - (peer.center.y + phh) },
      { side: 'right', align: dy, rawGap: dragged.center.x - dhw - (peer.center.x + phw) },
      { side: 'left', align: dy, rawGap: peer.center.x - phw - (dragged.center.x + dhw) },
    ]
    for (const c of cases) {
      if (c.align > config.alignTol) continue
      if (c.rawGap < 0 || c.rawGap > config.maxGap) continue // overlapping or too far
      const gap = Math.max(0, Math.round(c.rawGap * 10) / 10) // tidy source: 0.1u steps
      const score = c.rawGap + c.align // most-attached, best-aligned wins
      if (best === null || score < best.score) {
        best = {
          ref: peer.name,
          side: c.side,
          gap,
          center: bindCenter(peer, dragged.size, c.side, gap),
          score,
        }
      }
    }
  }

  if (best === null) return null
  const { score: _score, ...binding } = best
  return binding
}
