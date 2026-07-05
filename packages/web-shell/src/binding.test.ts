import { describe, it, expect } from 'vitest'
import { findBinding, type BindBox, type BindConfig } from './binding'

const CONFIG: BindConfig = { alignTol: 0.5, maxGap: 1.2 }

const peer = (name: string, x: number, y: number, width = 4, height = 2): BindBox => ({
  name,
  center: { x, y },
  size: { width, height },
})

// A dragged node is just a center + size (no name yet matters).
const dragged = (x: number, y: number, width = 2, height = 1) => ({
  center: { x, y },
  size: { width, height },
})

describe('findBinding', () => {
  it('binds below a peer when aligned and just under it', () => {
    // peer img spans y 4..6; dragged top edge at y ~3.4 -> gap ~0.6
    const b = findBinding(dragged(8, 2.9), [peer('img', 8, 5)], CONFIG)
    expect(b).not.toBeNull()
    expect(b!.ref).toBe('img')
    expect(b!.side).toBe('below')
    expect(b!.gap).toBeCloseTo(0.6) // (6-... ) rounded to 0.1
    // resolved center is column-aligned to the peer and honours the gap
    expect(b!.center.x).toBeCloseTo(8)
    expect(b!.center.y).toBeCloseTo(5 - 1 - b!.gap - 0.5)
  })

  it('binds to the right when aligned on y and just past the right edge', () => {
    // peer spans x 6..10; dragged left edge at x 10.5 -> gap 0.5
    const b = findBinding(dragged(11.5, 5), [peer('img', 8, 5)], CONFIG)
    expect(b).not.toBeNull()
    expect(b!.side).toBe('right')
    expect(b!.center.y).toBeCloseTo(5)
  })

  it('returns null when misaligned on the perpendicular axis', () => {
    // under the peer vertically but far off to the side (dx = 2 > alignTol)
    expect(findBinding(dragged(10, 2.9), [peer('img', 8, 5)], CONFIG)).toBeNull()
  })

  it('returns null when the gap exceeds maxGap (pulled away -> detach)', () => {
    // dragged top edge well below the peer bottom: gap ~2 > 1.2
    expect(findBinding(dragged(8, 1), [peer('img', 8, 5)], CONFIG)).toBeNull()
  })

  it('returns null when overlapping the peer (no side to attach to)', () => {
    expect(findBinding(dragged(8, 5), [peer('img', 8, 5)], CONFIG)).toBeNull()
  })

  it('picks the nearest peer/side when several qualify', () => {
    // closer peer just above, farther peer just below; the smaller gap wins
    const near = peer('near', 8, 3.9) // spans y 2.9..4.9; dragged below-of-near? dragged at y ~5.5
    const far = peer('far', 8, 8) // spans y 7..9
    const b = findBinding(dragged(8, 5.55), [near, far], CONFIG)
    expect(b).not.toBeNull()
    expect(b!.ref).toBe('near')
    expect(b!.side).toBe('above')
  })
})
