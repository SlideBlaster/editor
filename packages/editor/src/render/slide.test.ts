import { describe, it, expect } from 'vitest'
import { parsePicture } from '../tikz/parse'
import { resolveLayout } from '../layout/resolve'
import type { Measurer } from '../layout/measure'
import { renderSlide, connectorsOf, slideStylesheet, slideStepCount } from './slide'

const fixed = (width: number, height: number): Measurer => ({ measure: () => ({ width, height }) })

const PICTURE = parsePicture(
  [
    '\\node[title] (title) {};',
    '\\node[body, below=0.7 of title, text width=12] (intro) {hi};',
    '\\node[note] (o2) at (10,3) {$x$};',
    '\\draw[->] (intro) -- (o2);',
  ].join('\n'),
)

describe('renderSlide', () => {
  const html = renderSlide(PICTURE, resolveLayout(PICTURE, fixed(2, 1)))

  it('produces the layered structure (slide > geometry svg + content)', () => {
    expect(html).toContain('<div class="sb-slide">')
    expect(html).toContain('<svg class="sb-geometry" viewBox="0 0 16 9"')
    expect(html).toContain('<div class="sb-content">')
  })

  it('draws one geometry box per node', () => {
    expect(html.match(/<rect /g)).toHaveLength(3)
  })

  it('positions the o2 content node by percentage (center 10,3, size 2x1)', () => {
    // left = (10 - 1)/16 = 56.25%, top = (9 - 3 - 0.5)/9 = 61.1111%, width = 2/16 = 12.5%
    expect(html).toContain('left:56.25%;top:61.1111%;width:12.5%')
    // and it carries the rendered (math-placeholder) content
    expect(html).toContain('<span class="sb-math" data-mode="inline">x</span>')
  })

  it('renders the arrow between the two node anchors, with a head from ->', () => {
    // intro center (0,-1.7) -> svg (0,10.7); o2 center (10,3) -> svg (10,6)
    expect(html).toContain(
      '<path class="sb-arrow" data-arrow="0" d="M 0,10.7 L 10,6" marker-end="url(#sb-arrow-end)"/>',
    )
  })

  it('connectorsOf resolves endpoints to node centers with a forward head', () => {
    const connectors = connectorsOf(PICTURE, resolveLayout(PICTURE, fixed(2, 1)))
    expect(connectors).toHaveLength(1)
    expect(connectors[0]!.index).toBe(0)
    expect(connectors[0]!.heads).toEqual({ start: false, end: true })
    expect(connectors[0]!.points).toHaveLength(2)
    expect(connectors[0]!.points[1]).toEqual({ x: 10, y: 3 }) // o2 center
    expect(connectors[0]!.editable?.anchors[1]).toEqual({ kind: 'node', name: 'o2' })
  })

  it('resolves a node border anchor (name.anchor) to that edge, not the centre', () => {
    const picture = parsePicture(
      ['\\node[note] (o2) at (10,3) {x};', '\\draw[->] (5,5) -- (o2.north);'].join('\n'),
    )
    const connectors = connectorsOf(picture, resolveLayout(picture, fixed(2, 1)))
    // o2 center (10,3), size 2x1 -> north edge (10, 3.5)
    expect(connectors[0]!.points[1]).toEqual({ x: 10, y: 3.5 })
    expect(connectors[0]!.editable?.anchors[1]).toEqual({
      kind: 'node',
      name: 'o2',
      anchor: 'north',
    })
  })

  it('marks the title box with its style class', () => {
    expect(html).toContain('class="sb-box sb-style-title"')
  })

  it('tags content nodes with their model identity (data-node)', () => {
    expect(html).toContain('data-node="intro"')
    expect(html).toContain('data-node="o2"')
  })
})

describe('overlays: step count and whole-node reveal (ADR 0018)', () => {
  const deck = parsePicture(
    [
      '\\node[title] (title) {A};',
      '\\node[overlay={2-}] (later) at (4,4) {shows from step 2};',
      '\\node (build) at (8,4) {intro \\pause more};',
    ].join('\n'),
  )

  it('slideStepCount is the max step referenced by node overlays and inline content', () => {
    expect(slideStepCount(deck)).toBe(2)
    expect(slideStepCount(parsePicture('\\node (a) {plain};'))).toBe(1)
    expect(slideStepCount(parsePicture('\\node[overlay={4-}] (a) {x};'))).toBe(4)
  })

  it('a node with an inactive overlay is hidden with space reserved at that step', () => {
    const at1 = renderSlide(deck, resolveLayout(deck, fixed(2, 1)), { step: 1 })
    const at2 = renderSlide(deck, resolveLayout(deck, fixed(2, 1)), { step: 2 })
    // The `overlay={2-}` node carries its spec and is hidden on step 1, shown on step 2.
    expect(at1).toContain('data-overlay="2-"')
    expect(at1).toMatch(/class="sb-node sb-ov-hidden"[^>]*data-node="later"/)
    expect(at2).not.toContain('sb-ov-hidden')
  })

  it('authoring render (no step) shows every node, none hidden', () => {
    const all = renderSlide(deck, resolveLayout(deck, fixed(2, 1)))
    expect(all).toContain('data-node="later"')
    expect(all).not.toContain('sb-ov-hidden')
  })
})

describe('slideStylesheet: base layout for structured content blocks', () => {
  const css = slideStylesheet()

  it('lays columns out as a flex row (the inline flex:<width> does the proportion)', () => {
    expect(css).toContain('.sb-columns{display:flex')
    expect(css).toContain('.sb-column{min-width:0}')
  })

  it('gives a matrix spacing-only, centred cells', () => {
    expect(css).toContain('.sb-matrix{border-collapse:collapse')
    expect(css).toContain('.sb-matrix td{')
    expect(css).toContain('text-align:center')
  })
})
