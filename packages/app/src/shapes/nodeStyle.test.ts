import { describe, it, expect } from 'vitest'
import {
  withShape,
  withFillColor,
  withStroke,
  withStrokeColor,
  withLineWidth,
  withDash,
  withOpacity,
  withFillOpacity,
  withDrawOpacity,
  withCorners,
  withFontSize,
} from './nodeStyle'

describe('withShape', () => {
  it('adds a bare ellipse token', () => {
    expect(withShape(['draw'], 'ellipse')).toEqual(['draw', 'ellipse'])
  })
  it('rectangle is the default — drops any shape token', () => {
    expect(withShape(['draw', 'ellipse'], 'rectangle')).toEqual(['draw'])
    expect(withShape(['circle', 'draw'], 'rectangle')).toEqual(['draw'])
  })
  it('switching replaces the prior shape, not duplicates it', () => {
    expect(withShape(['circle'], 'ellipse')).toEqual(['ellipse'])
  })
  it('preserves the role class and unrelated tokens', () => {
    expect(withShape(['body', 'below=0.5 of title'], 'ellipse')).toEqual([
      'body',
      'below=0.5 of title',
      'ellipse',
    ])
  })
})

describe('withFillColor', () => {
  it('sets a fill colour', () => {
    expect(withFillColor(['draw'], 'red')).toEqual(['draw', 'fill=red'])
  })
  it('replaces an existing fill in place', () => {
    expect(withFillColor(['fill=red', 'draw'], 'blue')).toEqual(['fill=blue', 'draw'])
  })
  it('clears the fill on null but keeps fill opacity', () => {
    expect(withFillColor(['fill=red', 'fill opacity=0.5'], null)).toEqual(['fill opacity=0.5'])
  })
})

describe('withStroke', () => {
  it('turns the outline on with a bare draw', () => {
    expect(withStroke(['ellipse'], true)).toEqual(['ellipse', 'draw'])
  })
  it('is idempotent when already drawn (keeps draw=<color>)', () => {
    expect(withStroke(['draw=red'], true)).toEqual(['draw=red'])
  })
  it('turns the outline off — drops both draw forms', () => {
    expect(withStroke(['draw', 'thick'], false)).toEqual(['thick'])
    expect(withStroke(['draw=red'], false)).toEqual([])
  })
  it('does NOT strip draw opacity (a distinct knob)', () => {
    expect(withStroke(['draw', 'draw opacity=0.4'], false)).toEqual(['draw opacity=0.4'])
  })
})

describe('withStrokeColor', () => {
  it('sets draw=<color>, keeping the node drawn', () => {
    expect(withStrokeColor(['draw'], 'teal')).toEqual(['draw=teal'])
  })
  it('null resets to a bare draw (default stroke)', () => {
    expect(withStrokeColor(['draw=teal'], null)).toEqual(['draw'])
  })
  it('leaves draw opacity untouched', () => {
    expect(withStrokeColor(['draw', 'draw opacity=0.4'], 'red')).toEqual([
      'draw opacity=0.4',
      'draw=red',
    ])
  })
})

describe('withLineWidth', () => {
  it('sets a named width', () => {
    expect(withLineWidth(['draw'], 'thick')).toEqual(['draw', 'thick'])
  })
  it('replaces a prior name and drops explicit line width', () => {
    expect(withLineWidth(['thin', 'line width=0.8', 'draw'], 'very thick')).toEqual([
      'draw',
      'very thick',
    ])
  })
  it('null clears to the default width', () => {
    expect(withLineWidth(['thick', 'draw'], null)).toEqual(['draw'])
  })
})

describe('withDash', () => {
  it('sets a dash pattern', () => {
    expect(withDash(['draw'], 'dashed')).toEqual(['draw', 'dashed'])
  })
  it('replaces a prior pattern', () => {
    expect(withDash(['dotted', 'draw'], 'densely dashed')).toEqual(['draw', 'densely dashed'])
  })
  it('null is solid', () => {
    expect(withDash(['dashed', 'draw'], null)).toEqual(['draw'])
  })
})

describe('opacities', () => {
  it('sets and clears each independently', () => {
    expect(withOpacity(['draw'], 0.5)).toEqual(['draw', 'opacity=0.5'])
    expect(withFillOpacity(['draw'], 0.5)).toEqual(['draw', 'fill opacity=0.5'])
    expect(withDrawOpacity(['draw'], 0.5)).toEqual(['draw', 'draw opacity=0.5'])
    expect(withOpacity(['opacity=0.5', 'draw'], null)).toEqual(['draw'])
  })
  it('opacity and fill opacity do not clobber each other', () => {
    const a = withFillOpacity(['opacity=0.5'], 0.2)
    expect(a).toEqual(['opacity=0.5', 'fill opacity=0.2'])
    expect(withOpacity(a, null)).toEqual(['fill opacity=0.2'])
  })
})

describe('withCorners', () => {
  it('sets and clears rounded corners', () => {
    expect(withCorners(['draw'], 6)).toEqual(['draw', 'rounded corners=6'])
    expect(withCorners(['rounded corners=6', 'draw'], null)).toEqual(['draw'])
  })
})

describe('withFontSize', () => {
  it('adds a font size to a node that had none', () => {
    expect(withFontSize(['body'], 3.4)).toEqual(['body', 'font size=3.4'])
  })
  it('replaces a prior font size in place (position-stable)', () => {
    expect(withFontSize(['font size=2', 'body'], 5)).toEqual(['font size=5', 'body'])
  })
  it('null clears the override (back to the theme role size: class < node)', () => {
    expect(withFontSize(['font size=3', 'draw'], null)).toEqual(['draw'])
  })
  it('preserves the role class, placement, and other knobs', () => {
    expect(withFontSize(['title', 'below=0.5 of hd', 'draw'], 6)).toEqual([
      'title',
      'below=0.5 of hd',
      'draw',
      'font size=6',
    ])
  })
})
