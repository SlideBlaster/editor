/**
 * A real `LatexmlEngine` backed by the WASM build of LaTeXML: Perl 5.38.2 +
 * LaTeXML + XML::LibXML/XML::LibXSLT compiled to WebAssembly (see engine/). It
 * runs the emscripten `perl` loader under Node, which instantiates `perl.wasm`
 * and drives `latexml-driver.pl` (the in-process tex -> html5 pipeline).
 *
 * This is the acceptance oracle for the port: its output must match
 * `nativeLatexmlEngine` (system latexml) on the golden corpus. It is Node-only
 * (spawns a subprocess, reads the vendored engine from disk) and is never
 * imported from the package surface or a browser bundle.
 *
 * NOTE: today the engine loads LaTeXML's Perl + resources from the host install
 * (`/usr/share/perl5`) via emscripten NODERAWFS. Bundling LaTeXML into the WASM
 * FS for the browser is the remaining packaging step; the conversion itself is
 * 100% WASM (perl.wasm executes every stage).
 */
import { execFileSync } from 'node:child_process'
import { existsSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import type { LatexmlEngine } from './wasmLatexmlCompiler'

const here = dirname(fileURLToPath(import.meta.url))
const engineDir = join(here, 'engine')
const perlTree = join(engineDir, 'vendor', 'perl-5.38.2')

/** The emscripten `perl` JS loader (runs perl.wasm under Node). */
const PERL_LOADER = join(perlTree, 'perl')
/** In-WASM converter script. */
const DRIVER = join(engineDir, 'latexml-driver.pl')

// @INC for the WASM perl: patched overlay first (DB_File stub etc.), then the
// vendored core lib + the statically-linked XS module pure-perl halves, then the
// host LaTeXML + pure-perl deps (read from disk via NODERAWFS).
const INC = [
  join(engineDir, 'vendor', 'latexml-overlay'),
  join(perlTree, 'lib'),
  join(perlTree, 'cpan', 'XML-LibXML', 'lib'),
  join(perlTree, 'cpan', 'XML-LibXSLT', 'lib'),
  '/usr/share/perl5',
]

/** Whether the WASM engine is built and runnable under the current Node. */
export function wasmLatexmlAvailable(): boolean {
  return existsSync(PERL_LOADER) && existsSync(join(perlTree, 'perl.wasm')) && existsSync(DRIVER)
}

export const wasmLatexmlEngine: LatexmlEngine = {
  async convert(latexDocument: string): Promise<string> {
    const dir = mkdtempSync(join(tmpdir(), 'sb-wasm-latexml-'))
    try {
      const tex = join(dir, 'doc.tex')
      writeFileSync(tex, latexDocument, 'utf8')
      const args = [PERL_LOADER, ...INC.flatMap((p) => [`-I${p}`]), DRIVER, tex]
      const html = execFileSync('node', args, {
        cwd: perlTree,
        encoding: 'utf8',
        maxBuffer: 64 * 1024 * 1024,
        stdio: ['ignore', 'pipe', 'pipe'],
      })
      return html
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  },
}
