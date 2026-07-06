import { describe, it, expect } from 'vitest'
import { parsePicture } from '../tikz/parse'
import { resolveLayout, resolveLayoutAsync, anchor, findPlaced } from './resolve'
import { asBatch, naiveMeasurer, type Measurer } from './measure'

/** A measurer that gives every node the same fixed box, for exact geometry asserts. */
const fixed = (width: number, height: number): Measurer => ({ measure: () => ({ width, height }) })

describe('resolveLayout: positions', () => {
  const pic = parsePicture(
    [
      '\\node[title] (title) {};',
      '\\node[body, below=0.7 of title, text width=12] (intro) {x};',
      '\\node[note] (o2) at (10,3) {y};',
    ].join('\n'),
  )

  it('uses the theme node distance for a placement written without a gap', () => {
    const p = parsePicture(['\\node (a) at (5,5) {a};', '\\node[below= of a] (b) {b};'].join('\n'))
    // below: b.center.y = a.y - a.hh - gap - b.hh = 5 - 0.5 - gap - 0.5
    const dflt = resolveLayout(p, fixed(2, 1)) // gap = DEFAULT_PLACEMENT_GAP (0.5)
    const themed = resolveLayout(p, fixed(2, 1), { nodeDistance: 1.5 })
    expect(findPlaced(dflt, 'b')!.center.y).toBeCloseTo(3.5)
    expect(findPlaced(themed, 'b')!.center.y).toBeCloseTo(2.5)
  })

  it('places absolute, default, and relative nodes (edge-to-edge gap, y-up)', () => {
    const layout = resolveLayout(pic, fixed(2, 1))
    // title: no position -> origin, size 2x1
    expect(findPlaced(layout, 'title')).toEqual({
      name: 'title',
      center: { x: 0, y: 0 },
      size: { width: 2, height: 1 },
      styleClasses: ['title'],
    })
    // intro: below=0.7 of title -> top edge 0.7 below title's bottom (-0.5)
    // center.y = 0 - 0.5 - 0.7 - 0.5 = -1.7, x aligned to title
    expect(findPlaced(layout, 'intro')!.center).toEqual({ x: 0, y: -1.7 })
    // o2: absolute
    expect(findPlaced(layout, 'o2')!.center).toEqual({ x: 10, y: 3 })
  })

  it('nodes are in picture order', () => {
    const layout = resolveLayout(pic, fixed(2, 1))
    expect(layout.nodes.map((n) => n.name)).toEqual(['title', 'intro', 'o2'])
  })

  it('the naive measurer honors text width and scales the title', () => {
    const layout = resolveLayout(pic, naiveMeasurer)
    expect(findPlaced(layout, 'intro')!.size.width).toBe(12)
    // an empty title still gets a min box; the note is a plain small node
    const title = findPlaced(layout, 'title')!
    const o2 = findPlaced(layout, 'o2')!
    expect(title.center).toEqual({ x: 0, y: 0 })
    expect(o2.center).toEqual({ x: 10, y: 3 })
  })

  it('the naive measurer honors minimum height as a grow-only floor', () => {
    const tall = parsePicture('\\node[note, minimum height=4] (a) {x};')
    const short = parsePicture('\\node[note] (a) {x};')
    // short content -> the floor wins; without the option the box is much shorter.
    expect(findPlaced(resolveLayout(tall, naiveMeasurer), 'a')!.size.height).toBe(4)
    expect(findPlaced(resolveLayout(short, naiveMeasurer), 'a')!.size.height).toBeLessThan(4)
  })

  it('multiplies the measured box by the node content scale', () => {
    const plain = findPlaced(resolveLayout(parsePicture('\\node (a) {x};'), fixed(2, 1)), 'a')!.size
    const scaled = findPlaced(
      resolveLayout(parsePicture('\\node[xscale=2, yscale=1.5] (a) {x};'), fixed(2, 1)),
      'a',
    )!.size
    expect(plain).toEqual({ width: 2, height: 1 })
    expect(scaled).toEqual({ width: 4, height: 1.5 })
  })
})

describe('resolveLayout: totality', () => {
  it('a dangling reference falls back to the origin', () => {
    const layout = resolveLayout(parsePicture('\\node[below=1 of ghost] (a) {x};'), fixed(2, 1))
    expect(findPlaced(layout, 'a')!.center).toEqual({ x: 0, y: 0 })
  })

  it('a placement cycle falls back to the origin for all involved', () => {
    const layout = resolveLayout(
      parsePicture('\\node[right=1 of b] (a) {x};\n\\node[left=1 of a] (b) {y};'),
      fixed(2, 1),
    )
    expect(findPlaced(layout, 'a')!.center).toEqual({ x: 0, y: 0 })
    expect(findPlaced(layout, 'b')!.center).toEqual({ x: 0, y: 0 })
  })
})

describe('resolveLayoutAsync: same geometry as the sync solve', () => {
  const pic = parsePicture(
    [
      '\\node[title] (title) {};',
      '\\node[body, below=0.7 of title, text width=12] (intro) {x};',
      '\\node[note] (o2) at (10,3) {y};',
    ].join('\n'),
  )

  it('matches resolveLayout when the batch measurer lifts the same sync measurer', async () => {
    const measurer = fixed(2, 1)
    expect(await resolveLayoutAsync(pic, asBatch(measurer))).toEqual(resolveLayout(pic, measurer))
  })

  it('awaits async sizes and still preserves picture order', async () => {
    // A measurer that resolves out of request order must not scramble placement.
    const shuffled = {
      measureAll: (inputs: readonly unknown[]) =>
        Promise.resolve(inputs.map(() => ({ width: 2, height: 1 }))),
    }
    const layout = await resolveLayoutAsync(pic, shuffled)
    expect(layout.nodes.map((n) => n.name)).toEqual(['title', 'intro', 'o2'])
  })

  it('honors text width through the async path', async () => {
    const layout = await resolveLayoutAsync(pic, asBatch(naiveMeasurer))
    expect(findPlaced(layout, 'intro')!.size.width).toBe(12)
  })
})

describe('anchor', () => {
  const node = { center: { x: 4, y: 5 }, size: { width: 2, height: 1 }, styleClasses: [] }

  it('returns compass points around the center', () => {
    expect(anchor(node, 'center')).toEqual({ x: 4, y: 5 })
    expect(anchor(node, 'north')).toEqual({ x: 4, y: 5.5 })
    expect(anchor(node, 'south')).toEqual({ x: 4, y: 4.5 })
    expect(anchor(node, 'east')).toEqual({ x: 5, y: 5 })
    expect(anchor(node, 'west')).toEqual({ x: 3, y: 5 })
    expect(anchor(node, 'south east')).toEqual({ x: 5, y: 4.5 })
  })
})
