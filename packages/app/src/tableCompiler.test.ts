/**
 * The table compile cache is the async->sync bridge under editing stress: it must
 * compile a settled table once, coalesce a burst of keystrokes into a single
 * conversion (never one per keystroke), surface + cache failures without retrying,
 * and re-render only after the cache is warm. These tests drive it with a fake
 * Compile port and fake timers — no DOM, no real latexml.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { parseContent, type CompilePort, type SlideDocument } from '@slideblaster/editor'
import {
  renderOptions,
  installTableCompiler,
  scheduleTableCompile,
  ensureTables,
  resetTableCompiler,
} from './tableCompiler'

/** A one-node deck whose body is the given raw table LaTeX. */
function deckWithTable(latex: string): SlideDocument {
  return {
    meta: { entries: [] },
    frames: [
      {
        id: 's1',
        title: 'S',
        picture: { statements: [{ kind: 'node', options: [], content: parseContent(latex) }] },
      },
    ],
  }
}

const BASIC = '\\begin{tabular}{cc}a & b\\end{tabular}'

/** A fake Compile port that records every source it converts. */
function fakePort(
  convert: (latex: string) => Promise<string> = async (l) => `<table data-src="${l}"></table>`,
): CompilePort & { calls: string[] } {
  const calls: string[] = []
  return {
    calls,
    supports: (kind) => kind === 'table',
    tableToHtml: (latex) => {
      calls.push(latex)
      return convert(latex)
    },
  }
}

beforeEach(() => {
  resetTableCompiler()
  vi.useFakeTimers()
})
afterEach(() => {
  vi.useRealTimers()
  resetTableCompiler()
})

describe('tableCompiler: the async->sync bridge', () => {
  it('compiles a settled table once and serves it synchronously after onReady', async () => {
    const port = fakePort()
    let ready = 0
    installTableCompiler(port, { onReady: () => ready++ })

    const doc = deckWithTable(BASIC)
    expect(renderOptions.renderTable!(BASIC)).toBeUndefined() // cold: placeholder

    scheduleTableCompile(doc)
    await vi.advanceTimersByTimeAsync(300)

    expect(port.calls).toEqual([BASIC])
    expect(ready).toBe(1)
    expect(renderOptions.renderTable!(BASIC)).toBe(`<table data-src="${BASIC}"></table>`)
  })

  it('coalesces a burst of edits into a single conversion (no compile per keystroke)', async () => {
    const port = fakePort()
    installTableCompiler(port, {})

    // Ten intermediate sources typed within the debounce window; only the last settles.
    for (let n = 1; n <= 10; n++) {
      scheduleTableCompile(deckWithTable(`\\begin{tabular}{cc}a & ${n}\\end{tabular}`))
      await vi.advanceTimersByTimeAsync(50) // shorter than DEBOUNCE_MS
    }
    await vi.advanceTimersByTimeAsync(300)

    expect(port.calls).toEqual(['\\begin{tabular}{cc}a & 10\\end{tabular}'])
  })

  it('does not recompile a cached source on re-render (no onReady loop)', async () => {
    const port = fakePort()
    let ready = 0
    installTableCompiler(port, { onReady: () => ready++ })

    const doc = deckWithTable(BASIC)
    scheduleTableCompile(doc)
    await vi.advanceTimersByTimeAsync(300)
    scheduleTableCompile(doc) // the re-render onReady triggers
    await vi.advanceTimersByTimeAsync(300)

    expect(port.calls).toEqual([BASIC])
    expect(ready).toBe(1)
  })

  it('surfaces and caches a compile failure without retrying', async () => {
    const port = fakePort(async () => {
      throw new Error('bad tabular')
    })
    installTableCompiler(port, {})

    const doc = deckWithTable(BASIC)
    await ensureTables(doc)
    await ensureTables(doc) // second pass must not retry the failed source

    expect(port.calls).toEqual([BASIC])
    const html = renderOptions.renderTable!(BASIC)
    expect(html).toContain('sb-table-error')
    expect(html).toContain('bad tabular')
  })

  it('ensureTables compiles immediately without waiting for the debounce', async () => {
    const port = fakePort()
    installTableCompiler(port, {})

    await ensureTables(deckWithTable(BASIC)) // no timer advance
    expect(renderOptions.renderTable!(BASIC)).toBe(`<table data-src="${BASIC}"></table>`)
  })

  it('degrades gracefully with no Compile port', async () => {
    installTableCompiler(undefined, {})
    scheduleTableCompile(deckWithTable(BASIC))
    await vi.advanceTimersByTimeAsync(300)
    expect(renderOptions.renderTable!(BASIC)).toBeUndefined()
  })
})
