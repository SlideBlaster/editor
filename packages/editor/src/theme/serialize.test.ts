import { describe, it, expect } from 'vitest'
import { defaultTheme } from './theme'
import { serializeTheme, parseTheme, ThemeParseError } from './serialize'

describe('theme serialize/parse (canonical JSON)', () => {
  it('round-trips the default theme', () => {
    expect(parseTheme(serializeTheme(defaultTheme))).toEqual(defaultTheme)
  })

  it('serialization is canonical: deterministic, key-sorted, newline-terminated', () => {
    const a = serializeTheme(defaultTheme)
    const b = serializeTheme(parseTheme(a))
    expect(a).toBe(b)
    expect(a.endsWith('\n')).toBe(true)
    // top-level keys (2-space indent) are sorted alphabetically: aspect < id < style
    expect(a.indexOf('\n  "aspect":')).toBeGreaterThanOrEqual(0)
    expect(a.indexOf('\n  "aspect":')).toBeLessThan(a.indexOf('\n  "id":'))
    expect(a.indexOf('\n  "id":')).toBeLessThan(a.indexOf('\n  "style":'))
  })

  it('preserves region order (arrays are not key-sorted)', () => {
    const parsed = parseTheme(serializeTheme(defaultTheme))
    expect(parsed.layout.regions.map((r) => r.name)).toEqual(['title', 'content'])
  })

  it('throws ThemeParseError on invalid JSON', () => {
    expect(() => parseTheme('{ not json')).toThrow(ThemeParseError)
  })

  it('throws with a field path on a mistyped field', () => {
    const bad = { ...defaultTheme, style: { ...defaultTheme.style, nodeDistance: 'x' } }
    expect(() => parseTheme(JSON.stringify(bad))).toThrow(/style\.nodeDistance/)
  })

  it('reports a bad region rect field with its index path', () => {
    const bad = JSON.parse(serializeTheme(defaultTheme))
    bad.layout.regions[0].rect.x = 'nope'
    expect(() => parseTheme(JSON.stringify(bad))).toThrow(/layout\.regions\[0\]\.rect\.x/)
  })
})
