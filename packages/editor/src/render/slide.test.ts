import { describe, it, expect } from 'vitest'
import { parsePicture } from '../tikz/parse'
import { resolveLayout } from '../layout/resolve'
import type { Measurer } from '../layout/measure'
import { renderSlide, connectorsOf } from './slide'

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
