import { describe, it, expect } from 'vitest'
import { parseContent, type TextRun } from '@slideblaster/editor'
import { editableHtml, matchLatexOpener, matchMarkdown, matchMath } from './richText'

const html = (body: string, atoms: TextRun[] = []): string =>
  editableHtml(parseContent(body), atoms)

describe('editableHtml', () => {
  it('stamps provenance on style runs, per dialect', () => {
    expect(html('\\textbf{x}')).toBe('<strong data-run="latex:textbf">x</strong>')
    expect(html('**x**')).toBe('<strong data-run="md:**">x</strong>')
    expect(html('<b>x</b>')).toBe('<strong data-run="html:b">x</strong>')
    expect(html('\\emph{x}')).toBe('<em data-run="latex:emph">x</em>')
    expect(html('\\textit{x}')).toBe('<em data-run="latex:textit">x</em>')
    expect(html('*x*')).toBe('<em data-run="md:*">x</em>')
    expect(html('\\underline{x}')).toBe('<u data-run="latex:underline">x</u>')
    expect(html('<s>x</s>')).toBe('<s data-run="html:s">x</s>')
    expect(html('<mark>x</mark>')).toBe('<mark data-run="html:mark">x</mark>')
    expect(html('\\hl{x}')).toBe('<mark data-run="latex:hl">x</mark>')
    expect(html('==x==')).toBe('<mark data-run="md:==">x</mark>')
  })

  it('nests transparently and escapes text', () => {
    expect(html('**a \\emph{b}**')).toBe(
      '<strong data-run="md:**">a <em data-run="latex:emph">b</em></strong>',
    )
    expect(html('a < b')).toBe('a &lt; b')
  })

  it('typesets math as an atomic island carrying its source', () => {
    const out = html('$e=mc^2$')
    expect(out).toContain('class="rt-atom rt-math"')
    expect(out).toContain('contenteditable="false"')
    expect(out).toContain('data-tex="e=mc^2"')
    expect(out).toContain('data-display="0"')
    expect(out).toContain('katex') // actually typeset, not source text
  })

  it('renders lists as editable ul/ol with dialect provenance', () => {
    expect(html('- a\n- b')).toBe('<ul data-run="list:md"><li>a</li><li>b</li></ul>')
  })

  it('freezes opaque constructs as indexed islands, in encounter order', () => {
    const atoms: TextRun[] = []
    const out = html('\\cite{k} and \\pause tail', atoms)
    expect(out).toContain('data-atom="0"')
    expect(out).toContain('data-atom="1"')
    expect(atoms.map((run) => run.kind)).toEqual(['cite', 'fragment'])
    expect(out).toContain('rt-chip') // an invisible \pause shows its source as a chip
  })
})

describe('matchMath', () => {
  it('matches a completed inline span and reports its start', () => {
    expect(matchMath('say $e=mc^2$')).toEqual({ start: 4, source: 'e=mc^2', display: false })
    expect(matchMath('$x$')).toEqual({ start: 0, source: 'x', display: false })
  })

  it('matches display math', () => {
    expect(matchMath('$$x+y$$')).toEqual({ start: 0, source: 'x+y', display: true })
  })

  it('rejects empty, escaped, and unfinished spans', () => {
    expect(matchMath('$$')).toBeNull() // just typed the display opener
    expect(matchMath('cost \\$5 and \\$6$')).toBeNull() // escaped dollars are literals
    expect(matchMath('$ $')).toBeNull() // whitespace-only body
    expect(matchMath('$x')).toBeNull()
  })
})

describe('matchMarkdown', () => {
  it('matches bold and italic closures', () => {
    expect(matchMarkdown('a **b**')).toEqual({ start: 2, marker: '**', body: 'b' })
    expect(matchMarkdown('a *b*')).toEqual({ start: 2, marker: '*', body: 'b' })
  })

  it('does not fire early while typing bold', () => {
    expect(matchMarkdown('**bold*')).toBeNull() // first closing star: wait for the second
    expect(matchMarkdown('**')).toBeNull()
    expect(matchMarkdown('* x *')).toBeNull() // opener followed by space is not emphasis
  })

  it('matches a highlight closure and reports its start', () => {
    expect(matchMarkdown('a ==b==')).toEqual({ start: 2, marker: '==', body: 'b' })
    expect(matchMarkdown('==x==')).toEqual({ start: 0, marker: '==', body: 'x' })
  })

  it('does not fire early while typing a highlight', () => {
    expect(matchMarkdown('==b=')).toBeNull() // first closing equals: wait for the second
    expect(matchMarkdown('==')).toBeNull()
    expect(matchMarkdown('====')).toBeNull() // empty body
  })
})

describe('matchLatexOpener', () => {
  it('fires the moment the brace completes a style command', () => {
    expect(matchLatexOpener('say \\textbf{')).toEqual({ start: 4, command: 'textbf' })
    expect(matchLatexOpener('\\emph{')).toEqual({ start: 0, command: 'emph' })
    expect(matchLatexOpener('\\underline{')).toEqual({ start: 0, command: 'underline' })
    expect(matchLatexOpener('\\hl{')).toEqual({ start: 0, command: 'hl' })
  })

  it('ignores other commands and incomplete openers', () => {
    expect(matchLatexOpener('\\frac{')).toBeNull()
    expect(matchLatexOpener('\\textbf')).toBeNull()
  })
})
