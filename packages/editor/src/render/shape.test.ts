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
