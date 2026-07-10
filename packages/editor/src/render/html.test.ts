import { describe, it, expect } from 'vitest'
import { parseContent } from '../content/parse'
import { renderContent } from './html'

const html = (body: string, step?: number) =>
  renderContent(parseContent(body), step !== undefined ? { step } : {})

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

  it('renders highlight (\\hl / == / <mark>) as a mark element', () => {
    expect(html('\\hl{a} ==b== <mark>c</mark>')).toBe(
      '<mark>a</mark> <mark>b</mark> <mark>c</mark>',
    )
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

  it('a point fragment renders as an empty marker', () => {
    expect(html('a \\pause b')).toBe('a <span class="sb-fragment" data-fragment="pause"></span> b')
  })
})

describe('renderContent: overlays (ADR 0018)', () => {
  it('show-all (no step) renders overlay children with an addressable marker, never hidden', () => {
    expect(html('\\only<2>{hi}')).toBe(
      '<span class="sb-overlay" data-ov="only" data-overlay="2">hi</span>',
    )
  })

  it('at a step, an inactive overlay is hidden with its space reserved', () => {
    expect(html('\\only<2>{hi}', 1)).toBe(
      '<span class="sb-overlay sb-ov-hidden" data-ov="only" data-overlay="2">hi</span>',
    )
    expect(html('\\only<2>{hi}', 2)).toBe(
      '<span class="sb-overlay" data-ov="only" data-overlay="2">hi</span>',
    )
  })

  it('\\pause hides the following content until its step (space reserved)', () => {
    expect(html('a \\pause b', 1)).toBe(
      'a <span class="sb-fragment" data-fragment="pause"></span>' +
        '<span class="sb-overlay sb-ov-hidden" data-appear="2"> b</span>',
    )
    expect(html('a \\pause b', 2)).toBe(
      'a <span class="sb-fragment" data-fragment="pause"></span> b',
    )
  })

  it('\\alert highlights only on its step; \\invisible inverts', () => {
    expect(html('\\alert<2>{x}', 1)).not.toContain('sb-ov-alert')
    expect(html('\\alert<2>{x}', 2)).toContain('sb-ov-alert')
    expect(html('\\invisible<2>{x}', 1)).not.toContain('sb-ov-hidden')
    expect(html('\\invisible<2>{x}', 2)).toContain('sb-ov-hidden')
  })

  it('a hidden \\pause tail with a block child wraps in a div, not a span', () => {
    expect(html('intro \\pause \\begin{itemize}\\item a\\end{itemize}', 1)).toContain(
      '<div class="sb-overlay sb-ov-hidden" data-appear="2">',
    )
  })
})

describe('renderContent: whole payloads', () => {
  it('empty is empty; an error is a labelled span', () => {
    expect(renderContent({ kind: 'empty' })).toBe('')
    expect(html('\\usetikzlibrary{x} hi')).toContain('class="sb-error"')
  })
})
