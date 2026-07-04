import { describe, it, expect } from 'vitest'
import fc from 'fast-check'
import { parseContent } from './parse'
import { serializeContent } from './serialize'
import { inlineStyleOf, dialectOf } from './styles'
import type { NodeContent, TextRun } from '../model/content'

// The normative worked corpus from design/format/node-content.md (A3a subset:
// examples 1, 2, 3, 6 — lists in 4/5 are A3b).
describe('worked corpus: parse', () => {
  it('1 — markdown bold', () => {
    expect(parseContent('Hello **world**')).toEqual<NodeContent>({
      kind: 'text',
      runs: [
        { kind: 'text', value: 'Hello ' },
        { kind: 'markdown', marker: '**', children: [{ kind: 'text', value: 'world' }] },
      ],
    })
  })

  it('2 — three dialects side by side, provenance kept', () => {
    expect(parseContent('Mix \\textbf{bold}, **md**, and <i>it</i>')).toEqual<NodeContent>({
      kind: 'text',
      runs: [
        { kind: 'text', value: 'Mix ' },
        { kind: 'latex', command: 'textbf', children: [{ kind: 'text', value: 'bold' }] },
        { kind: 'text', value: ', ' },
        { kind: 'markdown', marker: '**', children: [{ kind: 'text', value: 'md' }] },
        { kind: 'text', value: ', and ' },
        { kind: 'html', tag: 'i', children: [{ kind: 'text', value: 'it' }] },
      ],
    })
  })

  it('3 — inline math is opaque', () => {
    expect(parseContent('Euler $e^{i\\pi}+1=0$ done')).toEqual<NodeContent>({
      kind: 'text',
      runs: [
        { kind: 'text', value: 'Euler ' },
        { kind: 'math', display: false, source: 'e^{i\\pi}+1=0' },
        { kind: 'text', value: ' done' },
      ],
    })
  })

  it('6 — out-of-subset macro is a preserved error (ADR 0015)', () => {
    const content = parseContent('\\usetikzlibrary{calc} hi')
    expect(content.kind).toBe('error')
    if (content.kind === 'error') {
      expect(content.source).toBe('\\usetikzlibrary{calc} hi')
      expect(content.message).toContain('usetikzlibrary')
    }
  })
})

describe('worked corpus: byte-exact round-trip', () => {
  for (const inner of [
    'Hello **world**',
    'Mix \\textbf{bold}, **md**, and <i>it</i>',
    'Euler $e^{i\\pi}+1=0$ done',
    '\\usetikzlibrary{calc} hi', // error preserves source verbatim
    'display $$\\int_0^1 f$$ here',
    '<div>wrapped **and** nested</div>', // transparent container recurses
    'one *word* italic',
    'plain text with no constructs at all',
  ]) {
    it(`round-trips ${JSON.stringify(inner)}`, () => {
      expect(serializeContent(parseContent(inner))).toBe(`{${inner}}`)
    })
  }

  it('empty body -> empty', () => {
    expect(parseContent('')).toEqual<NodeContent>({ kind: 'empty' })
    expect(serializeContent({ kind: 'empty' })).toBe('{}')
  })

  it('a markdown list stays literal text in A3a (the fixture body), round-trips', () => {
    const body = '\n- point one\n- point two\n'
    expect(parseContent(body)).toEqual<NodeContent>({
      kind: 'text',
      runs: [{ kind: 'text', value: body }],
    })
    expect(serializeContent(parseContent(body))).toBe(`{${body}}`)
  })
})

describe('tri-dialect equivalence is derivable (styles)', () => {
  const firstRun = (inner: string): TextRun => {
    const c = parseContent(inner)
    if (c.kind !== 'text' || c.runs[0] === undefined) throw new Error('expected a run')
    return c.runs[0]
  }

  it('bold in all three dialects reads as one style, keeps distinct provenance', () => {
    for (const [inner, dialect] of [
      ['\\textbf{x}', 'latex'],
      ['**x**', 'md'],
      ['<b>x</b>', 'html'],
    ] as const) {
      const run = firstRun(inner)
      expect(inlineStyleOf(run)).toBe('bold')
      expect(dialectOf(run)).toBe(dialect)
    }
  })

  it('emph and textit both read italic but stay distinct runs', () => {
    expect(inlineStyleOf(firstRun('\\emph{x}'))).toBe('italic')
    expect(inlineStyleOf(firstRun('\\textit{x}'))).toBe('italic')
    expect(firstRun('\\emph{x}')).not.toEqual(firstRun('\\textit{x}'))
  })
})

// Property: any concatenation of canonical fragments is itself canonical —
// serialize(parse(inner)) == {inner}. Fragments carry no leading/trailing chars
// that would fuse across a boundary into a new construct.
const fragment = fc.constantFrom(
  'Hello ',
  'world',
  'foo bar',
  'a, b',
  '**bold**',
  '\\emph{y}',
  '\\textbf{z}',
  '<i>q</i>',
  '<b>r</b>',
  '$a+b$',
  '$$x$$',
)

describe('property: canonical fragments concatenate to canonical bodies', () => {
  it('serialize(parse(inner)) == {inner}', () => {
    fc.assert(
      fc.property(fc.array(fragment, { maxLength: 6 }), (parts) => {
        const inner = parts.join('')
        return serializeContent(parseContent(inner)) === `{${inner}}`
      }),
    )
  })
})
