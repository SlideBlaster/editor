import { describe, it, expect } from 'vitest'
import { parseContent } from '../content/parse'
import { parsePicture } from '../tikz/parse'
import { resolveLayout } from '../layout/resolve'
import type { Measurer } from '../layout/measure'
import { renderContent, type RenderOptions } from './html'
import { renderSlide } from './slide'

const html = (body: string, options?: RenderOptions) => renderContent(parseContent(body), options)
const fixed = (w: number, h: number): Measurer => ({ measure: () => ({ width: w, height: h }) })

describe('renderContent: citation seams', () => {
  it('an inline cite is a [?] placeholder until the bibliography resolves', () => {
    expect(html('See \\cite{knuth1984}')).toBe('See <span class="sb-cite">[?]</span>')
  })

  it('lets the app inject the resolved cite marker', () => {
    const out = html('See \\cite{a, b}', { renderCite: (keys) => `[${keys.join('|')}]` })
    expect(out).toBe('See <span class="sb-cite">[a|b]</span>')
  })

  it('falls back to [?] when the cite seam returns undefined', () => {
    expect(html('\\cite{x}', { renderCite: () => undefined })).toBe(
      '<span class="sb-cite">[?]</span>',
    )
  })

  it('printbibliography is a render-pending placeholder, then the injected list', () => {
    expect(html('\\printbibliography{}')).toBe(
      '<div class="sb-deferred" data-feature="bibliography">bibliography &mdash; render pending</div>',
    )
    expect(
      html('\\printbibliography{}', { renderBibliography: () => '<ol><li>Knuth</li></ol>' }),
    ).toBe('<div class="sb-bibliography"><ol><li>Knuth</li></ol></div>')
  })

  it('a citefootnote marker takes its number from the per-slide footnote sink', () => {
    const seen: string[][] = []
    const out = html('a\\citefootnote{k1}b\\citefootnote{k2, k3}', {
      footnotes: { add: (keys) => seen.push(keys) },
    })
    expect(out).toBe('a<sup class="sb-fn-marker">1</sup>b<sup class="sb-fn-marker">2</sup>')
    expect(seen).toEqual([['k1'], ['k2', 'k3']])
  })

  it('without a sink the marker renders a ? (headless/measurement render)', () => {
    expect(html('x\\citefootnote{k}')).toBe('x<sup class="sb-fn-marker">?</sup>')
  })
})

describe('renderSlide: footnote band', () => {
  const picture = parsePicture(
    [
      '\\node (a) at (2,7) {one\\citefootnote{knuth1984}};',
      '\\node (b) at (2,4) {two\\citefootnote{lamport94}};',
    ].join('\n'),
  )
  const slide = (options?: RenderOptions) =>
    renderSlide(picture, resolveLayout(picture, fixed(2, 1)), options)

  it('numbers footnotes across nodes in reading order and emits a slide-foot band', () => {
    const out = slide({ renderFootnoteText: (keys) => `REF(${keys.join(',')})` })
    // inline markers, numbered 1 then 2
    expect(out).toContain('one<sup class="sb-fn-marker">1</sup>')
    expect(out).toContain('two<sup class="sb-fn-marker">2</sup>')
    // the band, with the app-formatted reference text
    expect(out).toContain(
      '<div class="sb-footnotes"><div class="sb-footnote"><sup>1</sup> REF(knuth1984)</div>' +
        '<div class="sb-footnote"><sup>2</sup> REF(lamport94)</div></div>',
    )
  })

  it('falls back to the raw keys when no footnote-text seam is supplied', () => {
    const out = slide()
    expect(out).toContain('<div class="sb-footnote"><sup>1</sup> knuth1984</div>')
  })

  it('emits no band when the slide has no footnotes', () => {
    const plain = parsePicture('\\node (a) at (2,7) {plain};')
    expect(renderSlide(plain, resolveLayout(plain, fixed(2, 1)))).not.toContain('sb-footnotes')
  })
})
