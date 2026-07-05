/**
 * A `LatexmlEngine` backed by the system `latexml`/`latexmlpost` binaries, for
 * TESTS ONLY. It is the oracle: the WASM engine (engine/) must reproduce its
 * output. Node-only (uses child_process + fs); never imported from the package
 * surface or a browser bundle.
 *
 * Mirrors the prototype's server pipeline so goldens match native latexml:
 * latexml (tex -> xml) -> latexmlpost (xml -> html5), then inline the generated
 * CSS as a <style> block so `finalizeHtml` yields a self-contained fragment.
 */
import { execFileSync } from 'node:child_process'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { LatexmlEngine } from './wasmLatexmlCompiler'

/** Whether the native latexml toolchain is on PATH (so tests can skip when absent). */
export function latexmlAvailable(): boolean {
  try {
    execFileSync('latexml', ['--VERSION'], { stdio: 'ignore' })
    return true
  } catch {
    return false
  }
}

// LaTeXML writes these stylesheets next to the output; inline them so the fragment
// carries its own styling (the prototype did the same).
const CSS_FILES = ['LaTeXML.css', 'ltx-article.css']

export const nativeLatexmlEngine: LatexmlEngine = {
  async convert(latexDocument: string): Promise<string> {
    const dir = mkdtempSync(join(tmpdir(), 'sb-latexml-'))
    try {
      const tex = join(dir, 'doc.tex')
      const xml = join(dir, 'doc.xml')
      const html = join(dir, 'doc.html')
      writeFileSync(tex, latexDocument, 'utf8')
      execFileSync('latexml', [tex, `--dest=${xml}`], {
        cwd: dir,
        stdio: ['ignore', 'ignore', 'pipe'],
      })
      execFileSync('latexmlpost', [xml, `--dest=${html}`, '--format=html5'], {
        cwd: dir,
        stdio: ['ignore', 'ignore', 'pipe'],
      })
      const page = readFileSync(html, 'utf8')
      const styles = CSS_FILES.map((name) => {
        try {
          return `<style>${readFileSync(join(dir, name), 'utf8')}</style>`
        } catch {
          return '' // stylesheet not generated for this document
        }
      }).join('\n')
      // Inject the inlined CSS into the page so finalizeHtml lifts it out.
      return page.replace('</head>', `${styles}</head>`)
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  },
}
