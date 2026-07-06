import { describe, it, expect } from 'vitest'
import type { NodeStatement } from '../model/tikz'
import { parsePicture } from './parse'
import { serializePicture } from './serialize'
import { role, styleClasses, textWidth, minHeight, nodeScale } from './options'

const PICTURE = [
  '\\node[title] (title) {};',
  '\\node[body, below=0.7 of title, text width=12] (intro) {\n- point one\n- point two\n};',
  '\\node[note] (o2) at (10,3) {$\\int_0^1 f$};',
  '\\draw[->] (intro) -- (o2);',
].join('\n')

describe('parsePicture', () => {
  it('models nodes, coordinates, paths, and verbatim spans', () => {
    const pic = parsePicture(PICTURE)
    expect(pic.statements.map((s) => s.kind)).toEqual(['node', 'node', 'node', 'path'])

    const title = pic.statements[0] as NodeStatement
    expect(title.name).toBe('title')
    expect(title.options).toEqual(['title'])
    expect(title.content).toEqual({ kind: 'empty' })

    const intro = pic.statements[1] as NodeStatement
    expect(intro.name).toBe('intro')
    expect(intro.options).toEqual(['body', 'below=0.7 of title', 'text width=12'])
    // The body is a markdown list (A3b), framed by the surrounding newlines.
    expect(intro.content).toEqual({
      kind: 'text',
      runs: [
        { kind: 'text', value: '\n' },
        {
          kind: 'list',
          ordered: false,
          dialect: 'md',
          items: [
            { children: [{ kind: 'text', value: 'point one' }] },
            { children: [{ kind: 'text', value: 'point two' }] },
          ],
        },
        { kind: 'text', value: '\n' },
      ],
    })

    const o2 = pic.statements[2] as NodeStatement
    expect(o2.at).toEqual({ x: 10, y: 3 })
  })

  it('preserves an unrecognized statement verbatim', () => {
    const pic = parsePicture('\\foreach \\x in {1,2,3} { \\draw (\\x,0) -- (\\x,1); };')
    expect(pic.statements).toHaveLength(1)
    expect(pic.statements[0]!.kind).toBe('verbatim')
  })
})

describe('serializePicture', () => {
  it('is the canonical inverse of parse', () => {
    expect(serializePicture(parsePicture(PICTURE))).toBe(PICTURE)
  })

  it('regenerates only the moved node when one at changes (locality)', () => {
    const pic = parsePicture(PICTURE)
    const before = serializePicture(pic)
    const o2 = pic.statements[2] as NodeStatement
    o2.at = { x: 12, y: 3 }
    const after = serializePicture(pic)
    // Exactly one line differs; every other byte is untouched.
    const diff = before.split('\n').filter((line, i) => line !== after.split('\n')[i])
    expect(diff).toEqual(['\\node[note] (o2) at (10,3) {$\\int_0^1 f$};'])
    expect(after).toContain('\\node[note] (o2) at (12,3) {$\\int_0^1 f$};')
  })
})

describe('derived option views', () => {
  it('reads style classes and the title role', () => {
    const pic = parsePicture(PICTURE)
    expect(styleClasses(pic.statements[0] as NodeStatement)).toEqual(['title'])
    expect(role(pic.statements[0] as NodeStatement)).toBe('title')
    expect(styleClasses(pic.statements[1] as NodeStatement)).toEqual(['body'])
    expect(role(pic.statements[1] as NodeStatement)).toBeUndefined()
  })

  it('reads explicit size options (text width, minimum height), else undefined', () => {
    const pic = parsePicture(
      ['\\node[body, text width=12, minimum height=3.5] (a) {x};', '\\node[note] (b) {y};'].join(
        '\n',
      ),
    )
    const a = pic.statements[0] as NodeStatement
    const b = pic.statements[1] as NodeStatement
    expect(textWidth(a)).toBe(12)
    expect(minHeight(a)).toBe(3.5)
    expect(textWidth(b)).toBeUndefined()
    expect(minHeight(b)).toBeUndefined()
  })

  it('reads the content scale from scale / xscale / yscale (default 1)', () => {
    const pic = parsePicture(
      [
        '\\node (plain) {x};',
        '\\node[scale=1.5] (uniform) {x};',
        '\\node[xscale=2, yscale=1.25] (skewed) {x};',
      ].join('\n'),
    )
    expect(nodeScale(pic.statements[0] as NodeStatement)).toEqual({ x: 1, y: 1 })
    expect(nodeScale(pic.statements[1] as NodeStatement)).toEqual({ x: 1.5, y: 1.5 })
    expect(nodeScale(pic.statements[2] as NodeStatement)).toEqual({ x: 2, y: 1.25 })
  })
})
