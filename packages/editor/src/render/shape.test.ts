import { describe, it, expect } from 'vitest'
import type { NodeStatement } from '../model/tikz'
import { shapeGeometrySvg, type Rect } from './shape'

const RECT: Rect = { x: 0, y: 0, width: 4, height: 2 }
function node(...options: string[]): NodeStatement {
  return { kind: 'node', options, content: { kind: 'empty' } }
}

describe('shapeGeometrySvg', () => {
  it('a plain node is a transparent, unstroked rect (hit-test geometry only)', () => {
    const svg = shapeGeometrySvg(node(), RECT)
    expect(svg).toContain('<rect')
    expect(svg).toContain('class="sb-box"')
    expect(svg).not.toContain('sb-drawn')
    expect(svg).not.toContain('style=')
  })

  it('draw adds sb-drawn; a bare draw keeps the stylesheet default stroke', () => {
    const svg = shapeGeometrySvg(node('draw'), RECT)
    expect(svg).toContain('sb-drawn')
    expect(svg).not.toContain('stroke:')
  })

  it('emits every paint knob as inline style (which beats the .sb-drawn rule)', () => {
    const svg = shapeGeometrySvg(node('draw=red', 'fill=#00f', 'thick', 'dashed'), RECT)
    expect(svg).toContain('sb-drawn')
    expect(svg).toContain('fill:#00f')
    expect(svg).toContain('stroke:red')
    expect(svg).toContain('stroke-width:0.06')
    expect(svg).toContain('stroke-dasharray:0.15,0.1')
  })

  it('dotted strokes get round caps', () => {
    expect(shapeGeometrySvg(node('draw', 'dotted'), RECT)).toContain('stroke-linecap:round')
  })

  it('stroke knobs are suppressed on an undrawn node', () => {
    // A named width without `draw`: no stroke shows, so no stroke-width leaks out.
    const svg = shapeGeometrySvg(node('thick', 'fill=red'), RECT)
    expect(svg).not.toContain('sb-drawn')
    expect(svg).not.toContain('stroke-width')
    expect(svg).toContain('fill:red')
  })

  it('opacities and fill work without a stroke', () => {
    const svg = shapeGeometrySvg(node('fill=red', 'fill opacity=0.5', 'opacity=0.8'), RECT)
    expect(svg).toContain('fill-opacity:0.5')
    expect(svg).toContain('opacity:0.8')
  })

  it('rounded corners become rect rx/ry', () => {
    const svg = shapeGeometrySvg(node('draw', 'rounded corners=8'), RECT)
    expect(svg).toMatch(/rx="0\.6"/)
    expect(svg).toMatch(/ry="0\.6"/)
  })

  it('an ellipse node is an <ellipse> centred in the rect', () => {
    const svg = shapeGeometrySvg(node('draw', 'ellipse'), RECT)
    expect(svg).toContain('<ellipse')
    expect(svg).toContain('cx="2"')
    expect(svg).toContain('cy="1"')
    expect(svg).toContain('rx="2"')
    expect(svg).toContain('ry="1"')
  })

  it('passes extra classes after sb-box/sb-drawn (the slide renderer sb-style-*)', () => {
    const svg = shapeGeometrySvg(node('draw'), RECT, ['sb-style-note'])
    expect(svg).toContain('class="sb-box sb-drawn sb-style-note"')
  })
})

describe('shapeGeometrySvg outlines', () => {
  // RECT is {0,0,4,2}: centre (2,1), half-extents (2,1).
  it('diamond is a 4-point polygon at the edge midpoints', () => {
    const svg = shapeGeometrySvg(node('draw', 'diamond'), RECT)
    expect(svg).toContain('<polygon')
    expect(svg).toContain('points="2,0 4,1 2,2 0,1"')
  })

  it('triangle (isosceles triangle) is an apex-up 3-point polygon', () => {
    expect(shapeGeometrySvg(node('draw', 'isosceles triangle'), RECT)).toContain(
      'points="2,0 4,2 0,2"',
    )
  })

  it('trapezium narrows the top edge', () => {
    expect(shapeGeometrySvg(node('draw', 'trapezium'), RECT)).toContain('points="1,0 3,0 4,2 0,2"')
  })

  it('parallelogram slants the top edge right', () => {
    expect(shapeGeometrySvg(node('draw', 'parallelogram'), RECT)).toContain(
      'points="1,0 4,0 3,2 0,2"',
    )
  })

  it('regular polygon walks `sides` points around the box, first vertex at top', () => {
    const svg = shapeGeometrySvg(node('draw', 'regular polygon', 'regular polygon sides=6'), RECT)
    expect(svg).toContain('<polygon')
    expect(svg).toContain('2,0') // top vertex
    expect(svg).toContain('3.7321,0.5') // upper-right vertex (rx*cos30, ry*sin(-30))
  })

  it('cylinder is a <path> with elliptical caps (rx=w/2)', () => {
    const svg = shapeGeometrySvg(node('draw', 'cylinder'), RECT)
    expect(svg).toContain('<path')
    expect(svg).toContain('A 2,0.32') // cap arc: rx=2, ry=min(h*0.16, rx*0.6)=0.32
  })

  it('rounded rectangle renders as a stadium (rect fully rounded, rx=min(w,h)/2)', () => {
    const svg = shapeGeometrySvg(node('draw', 'rounded rectangle'), RECT)
    expect(svg).toContain('<rect')
    expect(svg).toMatch(/rx="1"/)
    expect(svg).toMatch(/ry="1"/)
  })
})
