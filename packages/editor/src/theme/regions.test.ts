import { describe, it, expect } from 'vitest'
import { defaultTheme } from './theme'
import { regionRects, regionAt, regionGuides } from './regions'

describe('regionRects (RelRect -> slide space, y-up)', () => {
  const rects = regionRects(defaultTheme)

  it('resolves the title band to the top of the 16x9 box', () => {
    const title = rects.find((r) => r.name === 'title')!
    expect(title.left).toBeCloseTo(0.96)
    expect(title.right).toBeCloseTo(15.04)
    expect(title.top).toBeCloseTo(8.55)
    expect(title.bottom).toBeCloseTo(7.02)
  })

  it('carries the region defaults', () => {
    const title = rects.find((r) => r.name === 'title')!
    expect(title.defaultClass).toBe('title')
    expect(title.defaultAnchor).toBe('top-left')
  })
})

describe('regionAt (creation-seeding hit test)', () => {
  it('finds the title region for a point in the top band', () => {
    expect(regionAt(defaultTheme, { x: 8, y: 8 })?.name).toBe('title')
  })
  it('finds the content region for a mid point', () => {
    expect(regionAt(defaultTheme, { x: 8, y: 4 })?.name).toBe('content')
  })
  it('returns undefined below every region', () => {
    expect(regionAt(defaultTheme, { x: 8, y: 0.1 })).toBeUndefined()
  })
})

describe('regionGuides (snap targets)', () => {
  const g = regionGuides(defaultTheme)
  it('contributes region x edges and y edges', () => {
    expect(g.xs).toContain(0.96) // shared left edge
    expect(g.ys.some((y) => Math.abs(y - 8.55) < 1e-6)).toBe(true) // title top
    expect(g.ys.some((y) => Math.abs(y - 0.54) < 1e-6)).toBe(true) // content bottom
  })
})
