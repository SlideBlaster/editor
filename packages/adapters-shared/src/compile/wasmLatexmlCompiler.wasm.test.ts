/**
 * The crux test: does the Compile adapter turn a real LaTeX table into correct
 * HTML using the *actual WASM build* of LaTeXML (Perl 5.38.2 + XML::LibXML +
 * XML::LibXSLT compiled to WebAssembly, run under Node)? This is the proof the
 * whole port exists for — no native latexml, no fakes, the wasm engine end to end.
 *
 * Runs the same table corpus through WasmLatexmlCompiler with the WASM engine and
 * asserts each yields a real, styled, embeddable LaTeXML table fragment. WASM
 * goldens are recorded alongside; regenerate after an intentional change with:
 *   UPDATE_GOLDENS=1 pnpm vitest run wasmLatexmlCompiler.wasm
 *
 * Skipped when the engine is not built (keeps CI green where perl.wasm is absent).
 */
import { describe, expect, it } from 'vitest'
import { readdirSync, readFileSync, writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import { WasmLatexmlCompiler } from './wasmLatexmlCompiler'
import { wasmLatexmlAvailable, wasmLatexmlEngine } from './wasmLatexmlEngine.testutil'

const here = dirname(fileURLToPath(import.meta.url))
const tablesDir = join(here, '__fixtures__', 'tables')
const cases = readdirSync(tablesDir)
  .filter((f) => f.endsWith('.tex'))
  .map((f) => f.replace(/\.tex$/, ''))

const compiler = new WasmLatexmlCompiler({ engine: wasmLatexmlEngine })
const update = process.env.UPDATE_GOLDENS === '1'

describe.skipIf(!wasmLatexmlAvailable())('WasmLatexmlCompiler end-to-end (WASM latexml)', () => {
  it('reports supports(table) when the engine is present', () => {
    expect(compiler.supports('table')).toBe(true)
    expect(cases.length).toBeGreaterThan(0)
  })

  for (const name of cases) {
    // First cold conversion boots LaTeXML; keep a generous per-case budget.
    it(`compiles ${name} to a LaTeXML HTML fragment via WASM`, async () => {
      const latex = readFileSync(join(tablesDir, `${name}.tex`), 'utf8').trim()
      const html = await compiler.tableToHtml(latex)

      // A real, styled, embeddable table fragment — not a page, not empty.
      expect(html).toContain('ltx_tabular')
      expect(html).toContain('<style')
      expect(html).not.toMatch(/<\/?(?:html|head|body)\b/)
      expect(html).not.toMatch(/<footer\b/)

      const goldenPath = join(tablesDir, `${name}.wasm.html`)
      if (update) {
        writeFileSync(goldenPath, html, 'utf8')
        return
      }
      expect(html).toBe(readFileSync(goldenPath, 'utf8'))
    }, 30_000)
  }
})
