import { describe, it, expect } from 'vitest'
import type { NodeStatement } from '../model/tikz'
import { parsePicture } from './parse'
import { serializePicture } from './serialize'
import { role, styleClasses } from './options'

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
    // A markdown list is A3b; in A3a it stays literal text (round-trips either way).
    expect(intro.content).toEqual({
      kind: 'text',
      runs: [{ kind: 'text', value: '\n- point one\n- point two\n' }],
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
})
