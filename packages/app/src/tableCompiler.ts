/**
 * Table compile cache + the shared RenderOptions. Contract: see tableCompiler.md.
 *
 * The Compile port (latexml) is ASYNC, but the render/measure seam (`renderTable`)
 * is SYNCHRONOUS by contract — exactly like KaTeX behind `renderMath`. This module
 * bridges the two: it keeps a source-keyed cache of compiled table HTML that the
 * seam reads instantly, and compiles cache misses out of band.
 *
 * The compile is DEBOUNCED and driven off the current document, so typing inside a
 * `tabular` does not fire a Perl conversion per keystroke — only the settled source
 * compiles. When a table finishes, `onReady` fires so the shell can drop the stale
 * measurement (the placeholder's box) and re-render at the table's true size.
 *
 * `renderOptions` composes this table seam with the KaTeX math seam and is the ONE
 * options object shared across every render surface (canvas, measurer, navigator,
 * export) — measurement and every painted surface must agree.
 */
import type {
  CompilePort,
  NodeContent,
  RenderOptions,
  SlideDocument,
  TextRun,
} from '@slideblaster/editor'
import { renderMath } from './math'
import { renderCite, renderBibliography, renderFootnoteText } from './citeCompiler'

/** How long the source must be quiet before we compile it (coalesces fast typing). */
const DEBOUNCE_MS = 200
/** Cap the cache so a long edit session's intermediate table sources cannot grow it without bound. */
const MAX_CACHE = 200

// source -> compiled fragment (success) or a surfaced error fragment. Either way the
// seam has a synchronous answer, so a source is compiled at most once.
const cache = new Map<string, string>()
const inflight = new Set<string>()

let compile: CompilePort | undefined
let onReady: (() => void) | undefined
let timer: ReturnType<typeof setTimeout> | null = null

/** The synchronous seam: compiled HTML, or undefined so the renderer shows "render pending". */
function renderTable(source: string): string | undefined {
  return cache.get(source)
}

/** The single shared render options — math, table, and citation seams — passed to
 *  every render call site (see citeCompiler for how citations resolve out of band). */
export const renderOptions: RenderOptions = {
  renderMath,
  renderTable,
  renderCite,
  renderBibliography,
  renderFootnoteText,
}

/**
 * Wire (or clear) the Compile port and the ready callback. Called once per shell
 * boot from createApp; `onReady` should reset the measurer and re-render. Absent or
 * unsupported port leaves tables as "render pending" placeholders (graceful degrade).
 */
export function installTableCompiler(
  port: CompilePort | undefined,
  hooks: { onReady?: () => void } = {},
): void {
  compile = port && port.supports('table') ? port : undefined
  onReady = hooks.onReady
}

/** Every distinct deferred-table source in the document — slide pictures AND their
 *  presenter-notes sidecars (ADR 0019), so a table in the notes compiles too. The cache
 *  is source-keyed and additive, so folding notes in cannot disturb slide tables. */
function tableSources(doc: SlideDocument): Set<string> {
  const out = new Set<string>()
  for (const frame of doc.frames) {
    for (const picture of frame.notes ? [frame.picture, frame.notes] : [frame.picture]) {
      for (const stmt of picture.statements) {
        if (stmt.kind === 'node') collectContent(stmt.content, out)
      }
    }
  }
  return out
}

function collectContent(content: NodeContent, out: Set<string>): void {
  if (content.kind === 'text') collectRuns(content.runs, out)
}

function collectRuns(runs: readonly TextRun[], out: Set<string>): void {
  for (const run of runs) {
    if (run.kind === 'deferred' && run.feature === 'table') out.add(run.source)
    else if ('children' in run) collectRuns(run.children, out)
    else if (run.kind === 'list') for (const item of run.items) collectRuns(item.children, out)
    else if (run.kind === 'columns') for (const col of run.columns) collectRuns(col.children, out)
    else if (run.kind === 'matrix')
      for (const row of run.rows) for (const cell of row) collectRuns(cell.children, out)
  }
}

/** Sources in the doc that still need compiling (cache miss, not already running). */
function pending(doc: SlideDocument): string[] {
  if (!compile) return []
  return [...tableSources(doc)].filter((s) => !cache.has(s) && !inflight.has(s))
}

function put(source: string, html: string): void {
  cache.set(source, html)
  while (cache.size > MAX_CACHE) {
    const oldest = cache.keys().next().value
    if (oldest === undefined) break
    cache.delete(oldest)
  }
}

async function compileNow(doc: SlideDocument): Promise<void> {
  const sources = pending(doc)
  if (!compile || sources.length === 0) return
  const engine = compile
  await Promise.all(
    sources.map(async (source) => {
      inflight.add(source)
      try {
        put(source, await engine.tableToHtml(source))
      } catch (err) {
        put(source, errorFragment(err))
      } finally {
        inflight.delete(source)
      }
    }),
  )
  onReady?.()
}

/**
 * Interactive path: after the document settles, compile any uncached tables, then
 * fire `onReady`. Returns immediately — the current paint uses placeholders for
 * not-yet-compiled tables and the table pops in when ready.
 */
export function scheduleTableCompile(doc: SlideDocument): void {
  if (pending(doc).length === 0) return
  if (timer !== null) clearTimeout(timer)
  timer = setTimeout(() => {
    timer = null
    void compileNow(doc)
  }, DEBOUNCE_MS)
}

/** Export path: compile every table in the doc now and await it (no debounce). */
export async function ensureTables(doc: SlideDocument): Promise<void> {
  if (timer !== null) {
    clearTimeout(timer)
    timer = null
  }
  await compileNow(doc)
}

/** Test seam: forget the port, cache, and pending timer. */
export function resetTableCompiler(): void {
  if (timer !== null) clearTimeout(timer)
  timer = null
  cache.clear()
  inflight.clear()
  compile = undefined
  onReady = undefined
}

function errorFragment(err: unknown): string {
  const message = err instanceof Error ? err.message : String(err)
  return `<div class="sb-table-error" title="${escapeAttr(message)}">table failed to compile</div>`
}

function escapeAttr(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
}
