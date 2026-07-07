import { describe, it, expect } from 'vitest'
import {
  createNode,
  naiveMeasurer,
  parseContent,
  renderSlide,
  resolveLayout,
  serializePicture,
} from '@slideblaster/editor'
import { SHAPES, shapeById, shapeCategories, shapeMatches, shapeNodeOptions } from './catalog'

describe('shapes catalogue', () => {
  it('ships the ellipse archetype as a draw+ellipse option preset', () => {
    expect(shapeById('ellipse')?.options).toEqual(['draw', 'ellipse'])
  })

  it('shapeNodeOptions appends grow-only size floors after the essence', () => {
    expect(shapeNodeOptions(shapeById('ellipse')!)).toEqual([
      'draw',
      'ellipse',
      'minimum width=3.2',
      'minimum height=2',
    ])
  })

  it('groups shapes into categories in first-seen order', () => {
    const categories = shapeCategories()
    expect(categories[0]!.name).toBe('General')
    expect(categories[0]!.shapes.map((shape) => shape.id)).toContain('ellipse')
  })

  it('matches by label and keyword, case-insensitively; empty query matches all', () => {
    const ellipse = shapeById('ellipse')!
    expect(shapeMatches(ellipse, 'ell')).toBe(true) // label
    expect(shapeMatches(ellipse, 'oval')).toBe(true) // keyword
    expect(shapeMatches(ellipse, 'OVAL')).toBe(true) // keyword, case-insensitive
    expect(shapeMatches(ellipse, 'arrow')).toBe(false)
    expect(shapeMatches(ellipse, '')).toBe(true)
  })
})

describe('dropping a shape (drag -> TikZ)', () => {
  // Mirrors the controller's insertShapeAt: createNode with the shape's options at a point.
  const ellipse = shapeById('ellipse')!
  const dropped = createNode(
    { statements: [] },
    {
      name: 'e1',
      at: { x: 8, y: 4.5 },
      options: shapeNodeOptions(ellipse),
      content: parseContent(ellipse.body),
    },
  )

  it('serializes to a canonical \\node with the shape options', () => {
    expect(serializePicture(dropped.picture)).toContain(
      '\\node[draw, ellipse, minimum width=3.2, minimum height=2] (e1) at (8,4.5) {}',
    )
  })

  it('renders as a stroked ellipse outline (same engine path as the palette thumbnail)', () => {
    const html = renderSlide(dropped.picture, resolveLayout(dropped.picture, naiveMeasurer))
    expect(html).toMatch(/<ellipse class="sb-box sb-drawn/)
    expect(html).not.toMatch(/<rect /)
  })
})

describe('the P0 launch set', () => {
  it('covers the daily-reach shapes across General and Flowchart', () => {
    const ids = SHAPES.map((shape) => shape.id)
    for (const id of [
      'rectangle',
      'rounded-rectangle',
      'ellipse',
      'circle',
      'diamond',
      'triangle',
      'trapezoid',
      'parallelogram',
      'hexagon',
      'cylinder',
      'flow-terminator',
    ]) {
      expect(ids).toContain(id)
    }
  })

  it('every shape is drawn (carries `draw`) with a positive default size and a unique id', () => {
    const ids = new Set<string>()
    for (const shape of SHAPES) {
      expect(shape.options).toContain('draw')
      expect(shape.size.width).toBeGreaterThan(0)
      expect(shape.size.height).toBeGreaterThan(0)
      expect(ids.has(shape.id)).toBe(false)
      ids.add(shape.id)
    }
  })
})

describe('dropping a polygon shape (drag -> TikZ -> <polygon>)', () => {
  const diamond = shapeById('diamond')!
  const dropped = createNode(
    { statements: [] },
    {
      name: 'd1',
      at: { x: 8, y: 4.5 },
      options: shapeNodeOptions(diamond),
      content: parseContent(diamond.body),
    },
  )

  it('serializes the diamond options to a canonical \\node', () => {
    expect(serializePicture(dropped.picture)).toContain(
      '\\node[draw, diamond, minimum width=2.8, minimum height=2.2] (d1) at (8,4.5) {}',
    )
  })

  it('renders as a <polygon> (the shared straight-edged outline)', () => {
    const html = renderSlide(dropped.picture, resolveLayout(dropped.picture, naiveMeasurer))
    expect(html).toContain('<polygon')
  })
})
