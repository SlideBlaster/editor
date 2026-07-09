import { describe, expect, it } from 'vitest'
import { isDocPath, isTikzPath, isEditablePath } from './workspace'

describe('workspace path classification', () => {
  it('recognizes decks by their compound extension', () => {
    expect(isDocPath('talks/demo.slideBlaster.md')).toBe(true)
    expect(isDocPath('notes.md')).toBe(false)
    expect(isDocPath('figures/tree.tikz')).toBe(false)
  })

  it('recognizes standalone figures by .tikz', () => {
    expect(isTikzPath('figures/tree.tikz')).toBe(true)
    expect(isTikzPath('demo.slideBlaster.md')).toBe(false)
    expect(isTikzPath('refs.bib')).toBe(false)
  })

  it('treats decks and figures as editable, other assets as not', () => {
    expect(isEditablePath('demo.slideBlaster.md')).toBe(true)
    expect(isEditablePath('figures/tree.tikz')).toBe(true)
    expect(isEditablePath('refs.bib')).toBe(false)
    expect(isEditablePath('img/logo.png')).toBe(false)
  })
})
