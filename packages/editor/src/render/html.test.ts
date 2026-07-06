import { describe, it, expect } from 'vitest'
import { parseContent } from '../content/parse'
import { renderContent } from './html'

const html = (body: string) => renderContent(parseContent(body))

describe('renderContent: inline', () => {
  it('renders markdown bold', () => {
    expect(html('Hello **world**')).toBe('Hello <strong>world</strong>')
  })

  it('collapses all three dialects to the same semantic element', () => {
    expect(html('\\textbf{a} **b** <b>c</b>')).toBe(
      '<strong>a</strong> <strong>b</strong> <strong>c</strong>',
    )
    expect(html('\\emph{a} *b* <i>c</i>')).toBe('<em>a</em> <em>b</em> <em>c</em>')
  })

  it('keeps structural html wraps as their tag', () => {
    expect(html('<div>x **y**</div>')).toBe('<div>x <strong>y</strong></div>')
  })

  it('escapes text and does not allow injection', () => {
    expect(html('a < b & c')).toBe('a &lt; b &amp; c')
  })
})

describe('renderContent: math seam', () => {
  it('defaults to a source-carrying placeholder', () => {
    expect(html('$x^2$')).toBe('<span class="sb-math" data-mode="inline">x^2</span>')
    expect(html('$$x^2$$')).toBe('<span class="sb-math" data-mode="display">x^2</span>')
  })

  it('lets a KaTeX-style adapter be injected', () => {
    const out = renderContent(parseContent('$a$'), {
      renderMath: (src, display) => `[math ${display ? 'block' : 'inline'}: ${src}]`,
    })
    expect(out).toBe('[math inline: a]')
  })
})

describe('renderContent: blocks', () => {
  it('renders lists', () => {
    expect(html('\n- one\n- two\n')).toBe('\n<ul><li>one</li><li>two</li></ul>\n')
    expect(html('\n1. a\n2. b\n')).toBe('\n<ol><li>a</li><li>b</li></ol>\n')
  })

  it('renders columns as a flex row', () => {
    expect(html('\\begin{columns}\\column{0.5}left\\column{0.5}right\\end{columns}')).toBe(
      '<div class="sb-columns"><div class="sb-column" style="flex:0.5">left</div>' +
        '<div class="sb-column" style="flex:0.5">right</div></div>',
    )
  })

  it('renders a matrix as a table', () => {
    expect(html('\\matrix{a & b \\\\ c & d}')).toBe(
      '<table class="sb-matrix"><tbody>' +
        '<tr><td>a</td><td>b</td></tr><tr><td>c</td><td>d</td></tr>' +
        '</tbody></table>',
    )
  })

  it('renders images', () => {
    expect(html('\\image{fig.png}')).toBe('<img src="fig.png" alt="">')
    expect(html('![a cat](cat.png)')).toBe('<img src="cat.png" alt="a cat">')
  })
})

describe('renderContent: port-gated payloads are labelled, not dropped', () => {
  it('a deferred table shows a render-pending placeholder', () => {
    expect(html('\\begin{tabular}{cc}a & b\\end{tabular}')).toBe(
      '<div class="sb-deferred" data-feature="table">table &mdash; render pending</div>',
    )
  })

  it('lets a Compile-port adapter inject the compiled table HTML', () => {
    const out = renderContent(parseContent('\\begin{tabular}{cc}a & b\\end{tabular}'), {
      renderTable: (src) => `[compiled: ${src}]`,
    })
    expect(out).toBe(
      '<div class="sb-table" data-feature="table">[compiled: \\begin{tabular}{cc}a & b\\end{tabular}]</div>',
    )
  })

  it('falls back to the placeholder when the table seam returns undefined', () => {
    const out = renderContent(parseContent('\\begin{tabular}{cc}a & b\\end{tabular}'), {
      renderTable: () => undefined,
    })
    expect(out).toBe(
      '<div class="sb-deferred" data-feature="table">table &mdash; render pending</div>',
    )
  })

  it('an include shows its path (storage pending)', () => {
    expect(html('\\cat{shared/defs.tex}')).toBe(
      '<span class="sb-include" data-path="shared/defs.tex">[include: shared/defs.tex]</span>',
    )
  })

  it('a fragment is an empty marker carrying its step', () => {
    expect(html('\\only[=2]')).toBe(
      '<span class="sb-fragment" data-fragment="only" data-at="2"></span>',
    )
  })
})

describe('renderContent: whole payloads', () => {
  it('empty is empty; an error is a labelled span', () => {
    expect(renderContent({ kind: 'empty' })).toBe('')
    expect(html('\\usetikzlibrary{x} hi')).toContain('class="sb-error"')
  })
})
