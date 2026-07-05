import { describe, it, expect } from 'vitest'
import { resolveSnap, type SnapBox, type SnapConfig } from './snap'

// Threshold stays below grid/2 (0.25) so free zones exist between grid points —
// the same relationship the canvas enforces by deriving threshold from a pixel radius.
const CONFIG: SnapConfig = { threshold: 0.2, grid: 0.5, slideWidth: 16, slideHeight: 9 }
const noGrid: SnapConfig = { ...CONFIG, grid: 0 }

const box = (x: number, y: number, width = 2, height = 1): SnapBox => ({
  center: { x, y },
  size: { width, height },
})

describe('resolveSnap alignment', () => {
  it('snaps the dragged center-x onto a peer center-x within threshold', () => {
    const peer = box(8, 6)
    const { center, guides } = resolveSnap(box(8.15, 2), [peer], noGrid)
    expect(center.x).toBeCloseTo(8)
    expect(center.y).toBeCloseTo(2) // y untouched: no peer/guide/grid near it
    expect(guides).toContainEqual({ x1: 8, y1: 0, x2: 8, y2: 9, kind: 'align' })
  })

  it('snaps the dragged left edge onto a peer left edge', () => {
    // peer left edge = 8 - 1 = 7; dragged left edge should land on 7 -> center 8
    const peer = box(8, 6, 2, 1)
    const { center } = resolveSnap(box(8.15, 2, 2, 1), [peer], noGrid)
    expect(center.x).toBeCloseTo(8)
  })

  it('snaps to the slide center guide (x=8) with no peers', () => {
    const { center, guides } = resolveSnap(box(7.85, 4.5), [], noGrid)
    expect(center.x).toBeCloseTo(8)
    expect(center.y).toBeCloseTo(4.5) // slide center-y guide
    expect(guides.some((g) => g.kind === 'align' && g.x1 === 8)).toBe(true)
  })

  it('snaps to a slide third', () => {
    const { center } = resolveSnap(box(5.4, 2), [], noGrid)
    expect(center.x).toBeCloseTo(16 / 3)
  })

  it('leaves the center untouched when nothing is within threshold', () => {
    const { center, guides } = resolveSnap(box(3.1, 2.1), [], noGrid)
    expect(center.x).toBeCloseTo(3.1)
    expect(center.y).toBeCloseTo(2.1)
    expect(guides).toEqual([])
  })

  it('prefers the nearer of two candidate lines', () => {
    const near = box(8.4, 6)
    const far = box(9, 6)
    const { center } = resolveSnap(box(8.35, 2), [near, far], noGrid)
    expect(center.x).toBeCloseTo(8.4) // snaps to the closer peer alignment
  })
})

describe('resolveSnap grid', () => {
  it('snaps the center to the nearest grid multiple when no alignment wins', () => {
    const { center } = resolveSnap(box(3.05, 2.05), [], CONFIG)
    expect(center.x).toBeCloseTo(3.0)
    expect(center.y).toBeCloseTo(2.0)
  })

  it('does not grid-snap in the free zone between grid points', () => {
    const { center } = resolveSnap(box(3.25, 2.25), [], CONFIG)
    expect(center.x).toBeCloseTo(3.25) // 0.25 from either 3.0 or 3.5, beyond threshold
    expect(center.y).toBeCloseTo(2.25)
  })

  it('alignment beats grid on the same axis', () => {
    const peer = box(3.1, 6) // peer center 3.1 is nearer than grid 3.0
    const { center, guides } = resolveSnap(box(3.05, 2), [peer], CONFIG)
    expect(center.x).toBeCloseTo(3.1)
    expect(guides.some((g) => g.kind === 'align')).toBe(true)
  })
})

describe('resolveSnap spacing', () => {
  it('centers the dragged node in an equal gap between two flankers', () => {
    // left high edge 3, right low edge 11 -> centered at 7 (not on a slide guide).
    // Dragged node kept narrow (width 1) so no edge grazes the x=8 slide guide.
    const left = box(2, 5, 2, 2) // spans x 1..3, y 4..6
    const right = box(12, 5, 2, 2) // spans x 11..13, y 4..6
    const { center, guides } = resolveSnap(box(6.9, 5, 1, 1), [left, right], noGrid)
    expect(center.x).toBeCloseTo(7)
    const spaceGuides = guides.filter((g) => g.kind === 'space')
    expect(spaceGuides).toHaveLength(2)
  })

  it('does not apply spacing when a flanker does not overlap on the other axis', () => {
    const left = box(2, 1, 2, 2) // y 0..2, no overlap with dragged at y 5
    const right = box(12, 5, 2, 2)
    const { center } = resolveSnap(box(6.9, 5, 1, 1), [left, right], noGrid)
    expect(center.x).toBeCloseTo(6.9) // one flanker only -> no spacing, no alignment
  })

  it('alignment takes precedence over spacing on the same axis', () => {
    const left = box(2, 5, 2, 2)
    const right = box(12, 5, 2, 2)
    // a peer whose center-x (6.95) is nearer than the spacing center (7)
    const distractor = box(6.95, 8, 2, 1)
    const { center } = resolveSnap(box(6.92, 5, 1, 1), [left, right, distractor], noGrid)
    expect(center.x).toBeCloseTo(6.95)
  })
})
