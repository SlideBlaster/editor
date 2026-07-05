import { describe, expect, it } from 'vitest'
import type { CompilePort } from '@slideblaster/editor'
import {
  buildTableDocument,
  CompileError,
  finalizeHtml,
  WasmLatexmlCompiler,
  type LatexmlEngine,
} from './wasmLatexmlCompiler'

const TABLE = '\\begin{tabular}{lr}\\toprule A&B\\\\\\midrule x&1\\\\\\bottomrule\\end{tabular}'

// A stand-in for the unbuilt WASM engine, so the glue can be exercised end-to-end.
const fakeEngine = (impl: (doc: string) => string): LatexmlEngine => ({
  convert: async (doc) => impl(doc),
})

describe('buildTableDocument', () => {
  it('wraps the table in the prototype preamble and document body', () => {
    const doc = buildTableDocument(`  ${TABLE}  `)
    expect(doc).toContain('\\documentclass{article}')
    expect(doc).toContain('\\usepackage{booktabs}')
    expect(doc).toMatch(/\\begin\{document\}\n\\begin\{tabular\}/) // trimmed, no stray blank line
    expect(doc.trimEnd().endsWith('\\end{document}')).toBe(true)
  })
})

describe('finalizeHtml', () => {
  it('extracts the body and strips the LaTeXML footer', () => {
    const page =
      '<html><head><style>x</style></head><body><table class="ltx_tabular"></table>' +
      '<footer class="ltx_page_footer">generated</footer></body></html>'
    const out = finalizeHtml(page)
    expect(out).toContain('ltx_tabular')
    expect(out).toContain('<style>x</style>') // styling preserved -> self-contained fragment
    expect(out).not.toMatch(/<footer\b/)
  })

  it('throws on empty output rather than returning nothing', () => {
    expect(() => finalizeHtml('<body>   </body>')).toThrow(CompileError)
  })
})

describe('WasmLatexmlCompiler without an engine (current scaffold state)', () => {
  const compiler: CompilePort = new WasmLatexmlCompiler()

  it('reports it cannot compile tables', () => {
    expect(compiler.supports('table')).toBe(false)
  })

  it('throws a surfaced CompileError pointing at the roadmap', async () => {
    await expect(compiler.tableToHtml(TABLE)).rejects.toThrow(/engine is not built/)
  })
})

describe('WasmLatexmlCompiler with an injected engine (the glue contract)', () => {
  it('supports tables and returns the finalized fragment', async () => {
    const engine = fakeEngine(
      (doc) => `<html><body><table>${doc.includes('booktabs') ? 'ok' : 'no'}</table></body></html>`,
    )
    const compiler = new WasmLatexmlCompiler({ engine })
    expect(compiler.supports('table')).toBe(true)
    await expect(compiler.tableToHtml(TABLE)).resolves.toBe('<table>ok</table>')
  })

  it('wraps engine failures in a surfaced CompileError', async () => {
    const engine = fakeEngine(() => {
      throw new Error('boom')
    })
    const compiler = new WasmLatexmlCompiler({ engine })
    await expect(compiler.tableToHtml(TABLE)).rejects.toThrow(/latexml compile failed: boom/)
  })
})
