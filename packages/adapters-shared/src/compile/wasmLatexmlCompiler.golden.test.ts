/**
 * Golden test: does the Compile adapter turn a real LaTeX table into the correct
 * HTML? The unbuilt WASM engine is stood in for by the native `latexml` oracle
 * (nativeLatexmlEngine), so this exercises the true end-to-end path —
 * buildTableDocument -> latexml -> finalizeHtml — against checked-in goldens.
 *
 * The same goldens are the acceptance target for the WASM engine: when it lands,
 * swapping the engine and re-running this suite proves WASM matches native.
 *
 * Skipped when latexml is not on PATH (keeps CI green offline). Regenerate goldens
 * after an intentional change with:  UPDATE_GOLDENS=1 vitest run
 */
import { describe, expect, it } from 'vitest'
import { readdirSync, readFileSync, writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import { WasmLatexmlCompiler } from './wasmLatexmlCompiler'
import { latexmlAvailable, nativeLatexmlEngine } from './nativeLatexmlEngine.testutil'

const here = dirname(fileURLToPath(import.meta.url))
const tablesDir = join(here, '__fixtures__', 'tables')
const cases = readdirSync(tablesDir)
  .filter((f) => f.endsWith('.tex'))
  .map((f) => f.replace(/\.tex$/, ''))

const compiler = new WasmLatexmlCompiler({ engine: nativeLatexmlEngine })
const update = process.env.UPDATE_GOLDENS === '1'

describe.skipIf(!latexmlAvailable())(
  'WasmLatexmlCompiler end-to-end (native latexml oracle)',
  () => {
    it('compiles the corpus (and every case has a golden)', () => {
      expect(cases.length).toBeGreaterThan(0)
    })

    for (const name of cases) {
      it(`produces the golden HTML for ${name}`, async () => {
        const latex = readFileSync(join(tablesDir, `${name}.tex`), 'utf8').trim()
        const html = await compiler.tableToHtml(latex)

        // Correctness independent of the golden snapshot: a real, styled, embeddable
        // table fragment — not a full page, not empty, actually a LaTeXML table.
        expect(html).toContain('ltx_tabular')
        expect(html).toContain('<style')
        expect(html).not.toMatch(/<\/?(?:html|head|body)\b/)
        expect(html).not.toMatch(/<footer\b/) // generator footer element stripped

        const goldenPath = join(tablesDir, `${name}.html`)
        if (update) {
          writeFileSync(goldenPath, html, 'utf8')
          return
        }
        expect(html).toBe(readFileSync(goldenPath, 'utf8'))
      })
    }
  },
)
