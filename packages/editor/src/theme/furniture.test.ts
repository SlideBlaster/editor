import { describe, it, expect } from 'vitest'
import { defaultTheme, type Theme } from './theme'
import { furnitureHtml, furnitureCss } from './furniture'

const withFurniture = (f: Partial<Theme['furniture']>): Theme => ({
  ...defaultTheme,
  furniture: { ...defaultTheme.furniture, ...f },
})

describe('furnitureHtml', () => {
  it('renders nothing by default (page number off, no logo/bands)', () => {
    expect(furnitureHtml(defaultTheme, { index: 0, total: 5 })).toBe('')
  })

  it('renders a page number when shown, expanding {n} and {total}', () => {
    const t = withFurniture({
      pageNumber: { show: true, format: '{n} / {total}', anchor: 'bottom-right' },
    })
    const html = furnitureHtml(t, { index: 2, total: 5 })
    expect(html).toContain('class="sb-furniture"')
    expect(html).toContain('sb-fn-bottom-right')
    expect(html).toContain('3 / 5')
  })

  it('renders a logo img with its anchor and size', () => {
    const t = withFurniture({ logo: { asset: 'assets/logo.svg', anchor: 'top-right', size: 0.1 } })
    const html = furnitureHtml(t, { index: 0, total: 1 })
    expect(html).toContain('<img')
    expect(html).toContain('src="assets/logo.svg"')
    expect(html).toContain('sb-fn-top-right')
    expect(html).toContain('width:10%')
  })

  it('renders a footer band with left/center/right slots', () => {
    const t = withFurniture({ footer: { slots: { left: 'Deck', right: '{n}' } } })
    const html = furnitureHtml(t, { index: 0, total: 3 })
    expect(html).toContain('sb-fn-footer')
    expect(html).toContain('sb-fn-slot-left">Deck</span>')
    expect(html).toContain('sb-fn-slot-right">1</span>')
  })

  it('escapes furniture text', () => {
    const t = withFurniture({
      pageNumber: { show: true, format: '<b>{n}</b>', anchor: 'bottom-center' },
    })
    expect(furnitureHtml(t, { index: 0, total: 1 })).toContain('&lt;b&gt;1&lt;/b&gt;')
  })
})

describe('furnitureCss', () => {
  const css = furnitureCss(defaultTheme)
  it('lays out the chrome layer and anchors against the safe area', () => {
    expect(css).toContain('.sb-furniture{position:absolute;inset:0')
    expect(css).toContain('bottom:4%') // safeArea.bottom 0.04
    expect(css).toContain('.sb-fn-center{transform:translate(-50%,-50%)}')
  })
})
