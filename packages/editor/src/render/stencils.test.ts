import { describe, it, expect } from 'vitest'
import type { NodeStatement } from '../model/tikz'
import { nodeShape, stencilId } from '../tikz/options'
import { shapeGeometrySvg, type Rect } from './shape'
import { placeStencilPath, stencilPath } from './stencils'

const RECT: Rect = { x: 0, y: 0, width: 4, height: 2 }
function node(...options: string[]): NodeStatement {
  return { kind: 'node', options, content: { kind: 'empty' } }
}

describe('stencil token', () => {
  it('stencilId reads the id from a stencil=<id> token', () => {
    expect(stencilId(node('draw', 'stencil=flowchart.decision'))).toBe('flowchart.decision')
    expect(stencilId(node('draw', 'diamond'))).toBeUndefined()
    expect(stencilId(node('stencil='))).toBeUndefined() // empty id is not a stencil
  })

  it('a stencil token selects the stencil shape (over any bare shape token)', () => {
    expect(nodeShape(node('draw', 'stencil=flowchart.decision'))).toBe('stencil')
    expect(nodeShape(node('draw', 'ellipse', 'stencil=basic.cloud'))).toBe('stencil')
    expect(nodeShape(node('draw', 'diamond'))).toBe('diamond')
  })
})

describe('placeStencilPath', () => {
  it('bakes the box scale into coordinates (no transform attribute)', () => {
    // a unit diamond -> the box diamond, in absolute units
    expect(placeStencilPath('M 0.5 0 L 1 0.5 L 0.5 1 L 0 0.5 Z', RECT)).toBe(
      'M 2 0 L 4 1 L 2 2 L 0 1 Z',
    )
  })

  it('scales an arc radius per axis and passes its flags through', () => {
    // rx*width, ry*height; rotation/large-arc/sweep unchanged; endpoint scaled
    expect(placeStencilPath('M 0 0.5 A 0.5 0.5 0 0 1 1 0.5', RECT)).toBe('M 0 1 A 2 1 0 0 1 4 1')
  })

  it('handles cubic and quadratic control points', () => {
    expect(placeStencilPath('M 0 0 C 0.25 0 0.75 1 1 1', RECT)).toBe('M 0 0 C 1 0 3 2 4 2')
    expect(placeStencilPath('M 0 0 Q 0.5 1 1 0', RECT)).toBe('M 0 0 Q 2 2 4 0')
  })
})

describe('shapeGeometrySvg stencil branch', () => {
  it('renders a known stencil as one absolute <path>', () => {
    const svg = shapeGeometrySvg(node('draw', 'stencil=flowchart.decision'), RECT)
    expect(svg).toContain('<path')
    expect(svg).toContain('class="sb-box sb-drawn"')
    expect(svg).not.toContain('transform=') // scale is baked into the coords
    expect(svg).toContain('d="M 2 0 L 4 1 L 2 2 L 0 1 Z"')
  })

  it('an unknown stencil id falls through to the default box (keeps hit geometry)', () => {
    const svg = shapeGeometrySvg(node('draw', 'stencil=nope.missing'), RECT)
    expect(svg).toContain('<rect')
    expect(stencilPath('nope.missing')).toBeUndefined()
  })
})
