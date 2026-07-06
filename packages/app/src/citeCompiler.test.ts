/**
 * Citation resolution is the async->sync bridge for the bibliography: load the `.bib`
 * (Storage port) once, number every `\cite` deck-wide in document order, and serve the
 * seams synchronously so a slide re-renders in agreement. These tests drive it with a
 * fake Storage port and fake timers — no DOM, no files.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { parseContent, type SlideDocument, type StoragePort } from '@slideblaster/editor'
import {
  installCiteCompiler,
  scheduleCiteCompile,
  ensureCitations,
  renderCite,
  renderBibliography,
  renderFootnoteText,
  resetCiteCompiler,
} from './citeCompiler'

const BIB = `
@book{knuth1984, author = {Knuth, Donald E.}, title = {The TeXbook}, year = {1984}, publisher = {Addison-Wesley}}
@book{lamport94, author = {Lamport, Leslie}, title = {LaTeX}, year = {1994}, publisher = {Addison-Wesley}}
`

/** A deck: frontmatter entries + one node per body string. */
function deck(entries: Record<string, string>, bodies: string[]): SlideDocument {
  return {
    meta: { entries: Object.entries(entries).map(([key, value]) => ({ key, value })) },
    frames: bodies.map((body, i) => ({
      id: `s${i}`,
      title: 'S',
      picture: { statements: [{ kind: 'node', options: [], content: parseContent(body) }] },
    })),
  }
}

/** A fake Storage port that serves `files` from `readText` and records reads. */
function fakeStorage(files: Record<string, string>): StoragePort & { reads: string[] } {
  const reads: string[] = []
  return {
    reads,
    readText: async (path) => {
      reads.push(path)
      const f = files[path]
      if (f === undefined) throw new Error(`no such file: ${path}`)
      return f
    },
    read: async () => new Uint8Array(),
    list: async () => [],
    exists: async (p) => p in files,
    write: async () => {},
    remove: async () => {},
    watch: () => () => {},
  }
}

const withBib = (bodies: string[], style = 'numeric') =>
  deck({ bibliography: 'refs.bib', citationStyle: style }, bodies)

beforeEach(() => {
  resetCiteCompiler()
  vi.useFakeTimers()
})
afterEach(() => {
  vi.useRealTimers()
  resetCiteCompiler()
})

describe('citeCompiler: numbering + resolution', () => {
  it('numbers \\cite deck-wide in document order, across nodes and frames', async () => {
    installCiteCompiler(fakeStorage({ 'refs.bib': BIB }), {})
    // frame 0 cites lamport94 first, frame 1 cites both -> lamport94=1, knuth1984=2
    await ensureCitations(withBib(['see \\cite{lamport94}', 'and \\cite{knuth1984, lamport94}']))

    expect(renderCite(['lamport94'])).toBe('[1]')
    expect(renderCite(['knuth1984', 'lamport94'])).toBe('[2, 1]')
  })

  it('resolves nothing until the bibliography loads, then serves synchronously', async () => {
    installCiteCompiler(fakeStorage({ 'refs.bib': BIB }), {})
    const doc = withBib(['x \\cite{knuth1984}'])
    expect(renderCite(['knuth1984'])).toBeUndefined() // cold

    scheduleCiteCompile(doc)
    await vi.advanceTimersByTimeAsync(300)
    expect(renderCite(['knuth1984'])).toBe('[1]')
  })

  it('\\printbibliography lists the cited refs in citation order', async () => {
    installCiteCompiler(fakeStorage({ 'refs.bib': BIB }), {})
    await ensureCitations(withBib(['\\cite{lamport94} \\cite{knuth1984} \\printbibliography{}']))

    const bib = renderBibliography()!
    expect(bib).toContain('[1]')
    expect(bib).toContain('[2]')
    expect(bib.indexOf('Lamport')).toBeLessThan(bib.indexOf('Knuth')) // lamport cited first
    expect(bib).toContain('<em>The TeXbook</em>')
  })

  it('provides footnote reference text (the slide adds the number)', async () => {
    installCiteCompiler(fakeStorage({ 'refs.bib': BIB }), {})
    await ensureCitations(withBib(['claim\\citefootnote{knuth1984}']))

    const text = renderFootnoteText(['knuth1984'])!
    expect(text).toContain('Knuth, Donald E.')
    expect(text).toContain('(1984)')
    expect(text).toContain('<em>The TeXbook</em>')
    // an author ending in "." must not double the separator period
    expect(text).toContain('E. (1984)')
    expect(text).not.toContain('..')
  })

  it('supports the author-year style', async () => {
    installCiteCompiler(fakeStorage({ 'refs.bib': BIB }), {})
    await ensureCitations(withBib(['\\cite{knuth1984}'], 'author-year'))
    expect(renderCite(['knuth1984'])).toBe('(Knuth, 1984)')
  })

  it('marks a missing key instead of dropping it', async () => {
    installCiteCompiler(fakeStorage({ 'refs.bib': BIB }), {})
    await ensureCitations(withBib(['\\cite{ghost}']))
    expect(renderCite(['ghost'])).toContain('ghost?')
  })
})

describe('citeCompiler: graceful degradation', () => {
  it('no bibliography frontmatter -> citations stay unresolved (placeholder)', async () => {
    installCiteCompiler(fakeStorage({ 'refs.bib': BIB }), {})
    await ensureCitations(deck({}, ['\\cite{knuth1984}']))
    expect(renderCite(['knuth1984'])).toBeUndefined()
  })

  it('a missing .bib file resolves to unresolved citations, not a crash', async () => {
    const storage = fakeStorage({}) // refs.bib absent
    installCiteCompiler(storage, {})
    await ensureCitations(withBib(['\\cite{knuth1984}']))
    expect(renderCite(['knuth1984'])).toBeUndefined()
  })

  it('degrades with no Storage port', async () => {
    installCiteCompiler(undefined, {})
    await ensureCitations(withBib(['\\cite{knuth1984}']))
    expect(renderCite(['knuth1984'])).toBeUndefined()
  })
})

describe('citeCompiler: no redundant recompute (no onReady loop)', () => {
  it('does not recompute or re-fire onReady when nothing citation-relevant changed', async () => {
    const storage = fakeStorage({ 'refs.bib': BIB })
    let ready = 0
    installCiteCompiler(storage, { onReady: () => ready++ })

    const doc = withBib(['\\cite{knuth1984}'])
    scheduleCiteCompile(doc)
    await vi.advanceTimersByTimeAsync(300)
    scheduleCiteCompile(doc) // e.g. the onReady re-render
    await vi.advanceTimersByTimeAsync(300)

    expect(ready).toBe(1)
    expect(storage.reads).toEqual(['refs.bib']) // loaded once
  })

  it('recomputes when the citation style changes', async () => {
    installCiteCompiler(fakeStorage({ 'refs.bib': BIB }), {})
    await ensureCitations(withBib(['\\cite{knuth1984}'], 'numeric'))
    expect(renderCite(['knuth1984'])).toBe('[1]')

    await ensureCitations(withBib(['\\cite{knuth1984}'], 'author-year'))
    expect(renderCite(['knuth1984'])).toBe('(Knuth, 1984)')
  })
})
