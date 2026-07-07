import { describe, it, expect } from 'vitest'
import { parsePicture } from './parse'
import { serializePicture } from './serialize'
import type { NodeStatement } from '../model/tikz'
import {
  isDrawn,
  fillColor,
  strokeColor,
  lineWidthName,
  strokeWidthUnits,
  dashPattern,
  dashArray,
  opacity,
  fillOpacity,
  drawOpacity,
  cornerRadiusPt,
  cornerRadiusUnits,
  isStyleKnobToken,
} from './options'

/** A bare node carrying just these option tokens. */
function node(...options: string[]): NodeStatement {
  return { kind: 'node', options, content: { kind: 'empty' } }
}

describe('isDrawn / stroke + fill colour', () => {
  it('a bare draw or draw=<color> is drawn; a plain node is not', () => {
    expect(isDrawn(node('draw'))).toBe(true)
    expect(isDrawn(node('draw=red'))).toBe(true)
    expect(isDrawn(node('ellipse'))).toBe(false)
  })
  it('draw opacity alone does NOT make a node drawn', () => {
    expect(isDrawn(node('draw opacity=0.5'))).toBe(false)
  })
  it('reads fill and stroke colours from their own keys only', () => {
    expect(fillColor(node('fill=red'))).toBe('red')
    expect(strokeColor(node('draw=teal'))).toBe('teal')
    expect(strokeColor(node('draw'))).toBeUndefined()
    // fill= must not swallow `fill opacity=`, nor draw= the `draw opacity=`.
    expect(fillColor(node('fill opacity=0.5'))).toBeUndefined()
    expect(strokeColor(node('draw opacity=0.5'))).toBeUndefined()
  })
})

describe('line width', () => {
  it('resolves a named width, anchored so thin == the 0.03 default', () => {
    expect(lineWidthName(node('thick'))).toBe('thick')
    expect(strokeWidthUnits(node('thin'))).toBeCloseTo(0.03)
    expect(strokeWidthUnits(node('thick'))).toBeCloseTo(0.06)
  })
  it('an explicit line width=<pt> wins and tolerates a unit', () => {
    expect(strokeWidthUnits(node('line width=0.8'))).toBeCloseTo(0.06)
    expect(strokeWidthUnits(node('line width=0.8pt'))).toBeCloseTo(0.06)
  })
  it('no width token -> undefined (stylesheet default applies)', () => {
    expect(strokeWidthUnits(node('draw'))).toBeUndefined()
  })
})

describe('dash', () => {
  it('reads the pattern token', () => {
    expect(dashPattern(node('dashed'))).toBe('dashed')
    expect(dashPattern(node('densely dotted'))).toBe('densely dotted')
    expect(dashPattern(node('draw'))).toBeUndefined()
  })
  it('dotted patterns render as round dots', () => {
    expect(dashArray('dotted').round).toBe(true)
    expect(dashArray('dashed').round).toBe(false)
  })
})

describe('opacities are independent', () => {
  it('each key reads only itself', () => {
    const n = node('opacity=0.9', 'fill opacity=0.5', 'draw opacity=0.2')
    expect(opacity(n)).toBe(0.9)
    expect(fillOpacity(n)).toBe(0.5)
    expect(drawOpacity(n)).toBe(0.2)
  })
  it('opacity= does not match fill/draw opacity', () => {
    expect(opacity(node('fill opacity=0.5'))).toBeUndefined()
    expect(opacity(node('draw opacity=0.5'))).toBeUndefined()
  })
})

describe('rounded corners', () => {
  it('bare token uses the 4pt default; =<pt> reads the value (unit-tolerant)', () => {
    expect(cornerRadiusPt(node('rounded corners'))).toBe(4)
    expect(cornerRadiusPt(node('rounded corners=6'))).toBe(6)
    expect(cornerRadiusPt(node('rounded corners=2pt'))).toBe(2)
    expect(cornerRadiusPt(node('draw'))).toBeUndefined()
  })
  it('converts pt to slide units', () => {
    expect(cornerRadiusUnits(node('rounded corners=8'))).toBeCloseTo(0.6)
  })
})

describe('isStyleKnobToken', () => {
  it('marks paint/shape/width/dash bare tokens, not theme roles', () => {
    for (const t of [
      'draw',
      'ellipse',
      'circle',
      'rectangle',
      'rounded corners',
      'thick',
      'dashed',
    ])
      expect(isStyleKnobToken(t)).toBe(true)
    for (const t of ['title', 'body', 'note']) expect(isStyleKnobToken(t)).toBe(false)
  })
})

describe('round-trip: style tokens survive parse -> serialize', () => {
  it('keeps hex fills, coloured strokes, widths, dashes, corners, opacities verbatim', () => {
    const src =
      '\\node[draw=red, fill=#ff8800, thick, densely dashed, rounded corners=6, ' +
      'fill opacity=0.5, draw opacity=0.8, ellipse] (s) at (2,2) {};'
    expect(serializePicture(parsePicture(src))).toBe(src)
  })
})
