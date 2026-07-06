# table compiler (tableCompiler.ts)

Bridges the ASYNC Compile port (latexml) to the SYNCHRONOUS `renderTable` seam the
engine's `renderContent` reads — the same shape as KaTeX behind `renderMath`, but the
compile happens out of band and populates a cache the seam reads instantly.

`renderOptions` is the single shared `RenderOptions` — math seam + table seam +
citation seams (`renderCite`/`renderBibliography`/`renderFootnoteText` from
[citeCompiler](./citeCompiler.md)) — passed to every render surface (canvas, DOM
measurer, navigator, export) so measurement and every painted surface agree. It
replaces the old `mathOptions` at those call sites.

## The cache and the seam

- A `Map<source, html>` keyed by the table's exact LaTeX source. `renderTable(source)`
  returns the cached fragment or `undefined` (⇒ the renderer shows "render pending").
- A source is compiled **at most once**. Success stores the finalized fragment
  (`WasmLatexmlCompiler.tableToHtml` → inline `<style>` + table); a compile failure
  stores a surfaced `sb-table-error` fragment (never silent, never retried — the source
  is deterministic, and fixing it is a different key).
- The cache is capped (`MAX_CACHE`, FIFO) so a long edit session's intermediate table
  sources cannot grow it without bound.

## Compile lifecycle

- `installTableCompiler(port, { onReady })` — wire the Compile port and the ready
  callback once per shell boot. An absent or `supports('table') === false` port leaves
  every table as a placeholder (graceful degrade per the port contract).
- `scheduleTableCompile(doc)` — the interactive path. **Debounced** (`DEBOUNCE_MS`): the
  document must settle before any conversion runs, so typing inside a `tabular` never
  fires a Perl conversion per keystroke — only the settled source compiles. Returns
  immediately; the current paint uses placeholders and the table pops in on `onReady`.
- `ensureTables(doc)` — the export/presenter path. Compiles every table in the doc now
  and awaits it (no debounce), so a collected/exported deck — or a presented one — is
  never missing a table. The source walk covers each frame's slide picture **and its
  presenter-notes sidecar** (`frame.notes`, ADR 0019), so a table in the notes compiles
  too; the cache is source-keyed and additive, so notes never disturb slide tables.
- `onReady` (wired by createApp) resets the DOM measurer and re-renders: the placeholder
  box that was measured is dropped and the table re-measures at its true size. It fires
  after the cache is populated, so the re-render finds cache hits and does not re-compile
  (no loop).

## Why a synchronous seam over an async pre-pass

Measurement caches a node's box by content key. If a table were measured before it
compiled and then compiled in place, the measurer would keep the stale placeholder box.
Keeping the seam synchronous + resetting the measurer on `onReady` makes the ordering
explicit and correct: paint with what's cached, compile, then re-measure once.

`resetTableCompiler()` is a test seam that forgets the port, cache, inflight set, and
pending timer.
