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
    'note ==important== here', // markdown highlight
    'soul \\hl{warn} text', // latex highlight (soul)
    'lit <mark>up</mark> now', // html highlight
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

  it('the intro fixture body round-trips byte-exact (list handled in A3b)', () => {
    const body = '\n- point one\n- point two\n'
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

  it('highlight in all three dialects reads as one style, keeps distinct provenance', () => {
    for (const [inner, dialect] of [
      ['\\hl{x}', 'latex'],
      ['==x==', 'md'],
      ['<mark>x</mark>', 'html'],
    ] as const) {
      const run = firstRun(inner)
      expect(inlineStyleOf(run)).toBe('highlight')
      expect(dialectOf(run)).toBe(dialect)
    }
  })

  it('parses each highlight form to its provenance-faithful run', () => {
    expect(firstRun('\\hl{x}')).toEqual({
      kind: 'latex',
      command: 'hl',
      children: [{ kind: 'text', value: 'x' }],
    })
    expect(firstRun('==x==')).toEqual({
      kind: 'markdown',
      marker: '==',
      children: [{ kind: 'text', value: 'x' }],
    })
    expect(firstRun('<mark>x</mark>')).toEqual({
      kind: 'html',
      tag: 'mark',
      children: [{ kind: 'text', value: 'x' }],
    })
  })

  it('a lone or unclosed == stays literal text', () => {
    expect(parseContent('2 == 2 is true')).toEqual<NodeContent>({
      kind: 'text',
      runs: [{ kind: 'text', value: '2 == 2 is true' }],
    })
  })
})

describe('lists (A3b): all three dialects, nested, byte-exact for canonical form', () => {
  for (const inner of [
    '\n- one\n- two\n', // markdown, framed by newlines (the fixture shape)
    '\n- first\n- second $a^2+b^2=c^2$ \\appear\n', // corpus 4: math + fragment in an item
    '\n1. alpha\n2. beta\n', // ordered markdown
    '\\begin{itemize}\\item a\\item b\\end{itemize}', // LaTeX itemize
    '\\begin{enumerate}\\item a\\item b\\end{enumerate}', // LaTeX enumerate
    '<ul><li>a</li><li>b</li></ul>', // HTML unordered
    '<ol><li>a</li><li>b</li></ol>', // HTML ordered
    '<div>\\begin{itemize}\\item bold **text**\\item plain\\end{itemize}</div>', // corpus 5: html>latex>md
  ]) {
    it(`round-trips ${JSON.stringify(inner)}`, () => {
      expect(serializeContent(parseContent(inner))).toBe(`{${inner}}`)
    })
  }

  it('a markdown list is a run framed by its surrounding newlines', () => {
    expect(parseContent('\n- a\n- b\n')).toEqual<NodeContent>({
      kind: 'text',
      runs: [
        { kind: 'text', value: '\n' },
        {
          kind: 'list',
          ordered: false,
          dialect: 'md',
          items: [
            { children: [{ kind: 'text', value: 'a' }] },
            { children: [{ kind: 'text', value: 'b' }] },
          ],
        },
        { kind: 'text', value: '\n' },
      ],
    })
  })

  it('corpus 5: html wraps a LaTeX list whose item carries markdown (3 dialects nested)', () => {
    const content = parseContent(
      '<div>\\begin{itemize}\\item bold **text**\\item plain\\end{itemize}</div>',
    )
    expect(content.kind).toBe('text')
    if (content.kind !== 'text') return
    const div = content.runs[0]
    expect(div).toMatchObject({ kind: 'html', tag: 'div' })
    if (div?.kind !== 'html') return
    const list = div.children[0]
    expect(list).toMatchObject({ kind: 'list', dialect: 'latex', ordered: false })
    if (list?.kind !== 'list') return
    expect(list.items).toHaveLength(2)
    expect(list.items[0]!.children).toEqual([
      { kind: 'text', value: 'bold ' },
      { kind: 'markdown', marker: '**', children: [{ kind: 'text', value: 'text' }] },
    ])
  })

  it('non-canonical lists normalize on save (markers -> -, renumber)', () => {
    expect(serializeContent(parseContent('\n* x\n* y\n'))).toBe('{\n- x\n- y\n}')
    expect(serializeContent(parseContent('\n3. x\n7. y\n'))).toBe('{\n1. x\n2. y\n}')
  })
})

describe('A3c: images, includes, columns, matrix, richer fragments, deferred tables', () => {
  for (const inner of [
    '\\image{figures/plot.png}', // LaTeX image
    '![a caption](figures/plot.png)', // markdown image
    '\\cat{shared/defs.tex}', // include (Storage port deferred)
    'reveal \\only<2>{this} and \\appear that', // wrapping overlay + point fragment
    'build \\uncover<2->{more} then \\pause rest', // uncover range + pause
    '\\alert<3>{hot} and \\visible<1,3>{v} and \\invisible<2>{i}', // alert / visible / invisible
    '\\begin{itemize}\\item<2-> staged\\item plain\\end{itemize}', // \item<spec> overlay
    'html <appear> marker',
    '\\begin{columns}\\column{0.5}left\\column{0.5}**right**\\end{columns}', // columns (structured)
    '\\matrix{a & b \\\\ c & d}', // matrix (structured)
    '\\matrix[scale=2]{x & y}', // matrix with options
    '\\begin{tabular}{cc}a & b\\end{tabular}', // table (deferred to Compile, opaque)
  ]) {
    it(`round-trips ${JSON.stringify(inner)}`, () => {
      expect(serializeContent(parseContent(inner))).toBe(`{${inner}}`)
    })
  }

  const runOf = (inner: string): TextRun => {
    const c = parseContent(inner)
    if (c.kind !== 'text' || c.runs[0] === undefined) throw new Error('expected a run')
    return c.runs[0]
  }

  it('models images, includes, and stepped fragments structurally', () => {
    expect(runOf('\\image{fig.png}')).toEqual({
      kind: 'image',
      src: 'fig.png',
      alt: '',
      dialect: 'latex',
    })
    expect(runOf('![a cat](cat.png)')).toEqual({
      kind: 'image',
      src: 'cat.png',
      alt: 'a cat',
      dialect: 'md',
    })
    expect(runOf('\\cat{p.tex}')).toEqual({ kind: 'include', path: 'p.tex' })
    expect(runOf('\\only<2>{x}')).toEqual({
      kind: 'overlay',
      command: 'only',
      children: [{ kind: 'text', value: 'x' }],
      spec: { raw: '2' },
    })
    expect(runOf('\\pause')).toEqual({ kind: 'fragment', name: 'pause', dialect: 'latex' })
  })

  it('columns and matrix parse into a real structure (only their layout is deferred to B)', () => {
    const cols = runOf('\\begin{columns}\\column{0.5}left\\column{0.6}right\\end{columns}')
    expect(cols).toMatchObject({ kind: 'columns' })
    if (cols.kind !== 'columns') return
    expect(cols.columns.map((c) => c.width)).toEqual(['0.5', '0.6'])
    expect(cols.columns[0]!.children).toEqual([{ kind: 'text', value: 'left' }])

    const mx = runOf('\\matrix{a & b \\\\ c & d}')
    expect(mx).toMatchObject({ kind: 'matrix', options: '' })
    if (mx.kind !== 'matrix') return
    expect(mx.rows).toHaveLength(2)
    expect(mx.rows[0]).toHaveLength(2)
    expect(mx.rows[1]![1]!.children).toEqual([{ kind: 'text', value: 'd' }])
  })

  it('a table is preserved opaque, pending the Compile port (not an error)', () => {
    const table = runOf('\\begin{tabular}{cc}a & b\\end{tabular}')
    expect(table).toEqual({
      kind: 'deferred',
      feature: 'table',
      source: '\\begin{tabular}{cc}a & b\\end{tabular}',
    })
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
