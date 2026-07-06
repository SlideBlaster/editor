import { describe, it, expect } from 'vitest'
import { defaultTheme, themeStylesheet, type Theme } from './index'

describe('defaultTheme', () => {
  it('is a complete three-layer theme', () => {
    expect(defaultTheme.style.classes.title).toBeDefined()
    expect(defaultTheme.style.nodeDistance).toBe(0.5)
    expect(defaultTheme.layout.regions.map((r) => r.name)).toEqual(['title', 'content'])
    expect(defaultTheme.furniture.pageNumber?.show).toBe(false)
    expect(defaultTheme.aspect?.default).toBe('16:9')
  })

  it('regions seed a default class for creation', () => {
    const title = defaultTheme.layout.regions.find((r) => r.name === 'title')!
    expect(title.defaultClass).toBe('title')
    expect(title.defaultAnchor).toBe('top-left')
  })
})

describe('themeStylesheet (style layer -> scoped CSS)', () => {
  const css = themeStylesheet(defaultTheme)

  it('emits the palette as custom properties + background on .sb-slide', () => {
    expect(css).toContain('--sb-bg:#ffffff')
    expect(css).toContain('--sb-ink:#1b1e28')
    expect(css).toContain('--sb-accent:#3b6ea5')
    expect(css).toContain('background:var(--sb-bg)')
  })

  it('emits the base type (cqw) + line-height + ink on .sb-content', () => {
    expect(css).toContain('.sb-content{font-size:2.6cqw;line-height:1.3;color:var(--sb-ink)}')
  })

  it('emits each role as a .sb-slide-scoped class rule, sized in cqw', () => {
    expect(css).toContain('.sb-slide .sb-style-title{')
    expect(css).toContain('font-size:4.2cqw')
    expect(css).toContain('font-weight:bold')
    expect(css).toContain('letter-spacing:-0.01em')
    expect(css).toContain('color:var(--sb-ink)')
  })

  it('resolves a palette-key colour to its var and a literal colour verbatim', () => {
    const theme: Theme = {
      ...defaultTheme,
      style: {
        ...defaultTheme.style,
        classes: {
          a: { color: 'accent' }, // palette key -> var
          b: { color: '#ff0000' }, // literal -> verbatim
        },
      },
    }
    const out = themeStylesheet(theme)
    expect(out).toContain('.sb-slide .sb-style-a{color:var(--sb-accent)}')
    expect(out).toContain('.sb-slide .sb-style-b{color:#ff0000}')
  })

  it('emits a structured border with radius', () => {
    expect(css).toContain(
      '.sb-slide .sb-style-box{border:1px solid var(--sb-accent);border-radius:6px}',
    )
  })

  it('omits a rule for a class with no visual decls', () => {
    const theme: Theme = {
      ...defaultTheme,
      style: { ...defaultTheme.style, classes: { empty: {} } },
    }
    const out = themeStylesheet(theme)
    expect(out).not.toContain('.sb-style-empty')
  })
})
