import { describe, it, expect } from 'vitest'
import { parseContent } from './parse'
import { serializeContent } from './serialize'
import { dialectOf } from './styles'
import type { NodeContent, TextRun } from '../model/content'

// Citations parse to structured runs carrying only their keys; the bibliography and
// numbering are the render track's job (like math/tables). See design/format/node-content.md.
describe('citations: parse', () => {
  it('inline \\cite keeps its keys, trimmed', () => {
    expect(parseContent('See \\cite{knuth1984, lamport94} here')).toEqual<NodeContent>({
      kind: 'text',
      runs: [
        { kind: 'text', value: 'See ' },
        { kind: 'cite', keys: ['knuth1984', 'lamport94'] },
        { kind: 'text', value: ' here' },
      ],
    })
  })

  it('\\citefootnote carries its keys', () => {
    expect(parseContent('Claim.\\citefootnote{knuth1984}')).toEqual<NodeContent>({
      kind: 'text',
      runs: [
        { kind: 'text', value: 'Claim.' },
        { kind: 'citefootnote', keys: ['knuth1984'] },
      ],
    })
  })

  it('\\printbibliography{} is a keyless block run', () => {
    expect(parseContent('\\printbibliography{}')).toEqual<NodeContent>({
      kind: 'text',
      runs: [{ kind: 'printbibliography' }],
    })
  })

  it('a single-key cite is not confused with citefootnote (prefix)', () => {
    const runs = (parseContent('\\cite{a} and \\citefootnote{b}') as { runs: TextRun[] }).runs
    expect(runs[0]).toEqual({ kind: 'cite', keys: ['a'] })
    expect(runs[2]).toEqual({ kind: 'citefootnote', keys: ['b'] })
  })

  it('citations are latex-dialect (provenance)', () => {
    expect(dialectOf({ kind: 'cite', keys: ['a'] })).toBe('latex')
    expect(dialectOf({ kind: 'citefootnote', keys: ['a'] })).toBe('latex')
    expect(dialectOf({ kind: 'printbibliography' })).toBe('latex')
  })
})

describe('citations: byte-exact round-trip (canonical form)', () => {
  for (const inner of [
    'See \\cite{knuth1984} for details',
    'Two refs \\cite{knuth1984, lamport94} inline',
    'Claim.\\citefootnote{knuth1984} and more',
    '\\printbibliography{}',
    'mix \\textbf{bold} then \\cite{a, b} then **md**',
  ]) {
    it(`round-trips ${JSON.stringify(inner)}`, () => {
      expect(serializeContent(parseContent(inner))).toBe(`{${inner}}`)
    })
  }

  it('non-canonical spacing normalizes to comma-space', () => {
    expect(serializeContent(parseContent('\\cite{a,b,c}'))).toBe('{\\cite{a, b, c}}')
    expect(serializeContent(parseContent('\\printbibliography'))).toBe('{\\printbibliography{}}')
  })
})
