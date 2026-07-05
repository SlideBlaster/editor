/**
 * Compile port implemented with WASM latexml. Contract: see wasmLatexmlCompiler.md.
 *
 * The adapter is the JS glue around a single in-process conversion primitive,
 * `LatexmlEngine`, which is the compiled `emperl.wasm` + Perl driver
 * (see engine/README.md). The engine is NOT built yet — the Track-0 spike proved
 * it feasible and mapped the build (project-root spikes/wasm-latexml). Until an
 * engine is injected, `supports('table')` is false and `tableToHtml` throws a
 * surfaced error, so the editor degrades gracefully per the port contract.
 *
 * Everything that does not require the engine — the LaTeX document wrapping that
 * matches the prototype, and the standalone-HTML finalization — is real and
 * tested here against an injected fake engine.
 */
import type { CompileKind, CompilePort } from '@slideblaster/editor'

/**
 * The WASM latexml engine: one in-process tex-document -> LaTeXML-HTML5 transform.
 * Emscripten has no fork/exec, so this is a single Perl process driving the
 * LaTeXML API (`$converter->convert`), never a `latexml`+`latexmlpost` subprocess
 * pair. Implemented by engine/ once roadmap phases P0-P4 land; injected here.
 */
export interface LatexmlEngine {
  /**
   * Convert a full LaTeX document to a LaTeXML HTML5 page. The page must carry
   * its styling **inline** as `<style>` blocks (not `<link>` to external CSS), so
   * the finalized fragment is self-contained per the port contract. `finalizeHtml`
   * lifts those styles + the `<body>` out into the embeddable fragment.
   */
  convert(latexDocument: string): Promise<string>
}

export interface WasmLatexmlCompilerDeps {
  /**
   * The compiled engine, or a lazy loader for it. Absent = engine not built /
   * not bundled in this shell; the adapter reports `supports('table') === false`.
   */
  engine?: LatexmlEngine
}

/** Thrown when compilation cannot be performed or the engine fails. Surfaced, never silent. */
export class CompileError extends Error {
  override name = 'CompileError'
}

// The proven prototype preamble: the packages a slide table may rely on. Kept in
// sync with the table-compile oracle so WASM output matches native latexml.
const DOCUMENT_PREAMBLE = [
  '\\documentclass{article}',
  '\\usepackage{booktabs}',
  '\\usepackage{multirow}',
  '\\usepackage{threeparttable}',
  '\\usepackage{array}',
  '\\begin{document}',
].join('\n')

/** Wrap a bare LaTeX table environment in the minimal document latexml compiles. */
export function buildTableDocument(tableLatex: string): string {
  return `${DOCUMENT_PREAMBLE}\n${tableLatex.trim()}\n\\end{document}\n`
}

// LaTeXML appends a generator footer to its page; the slide renderer does not want it.
const FOOTER = /<footer class="ltx_page_footer">[\s\S]*?<\/footer>/g

/**
 * Reduce a LaTeXML HTML5 page to the self-contained fragment the renderer embeds:
 * the inline `<style>` blocks (so the table keeps its styling with no external
 * stylesheet) followed by the `<body>` content, with the generator footer removed.
 */
export function finalizeHtml(page: string): string {
  const styles = (page.match(/<style[^>]*>[\s\S]*?<\/style>/g) ?? []).join('\n')
  const body = page.match(/<body[^>]*>([\s\S]*?)<\/body>/)
  const inner = (body?.[1] ?? page).replace(FOOTER, '').trim()
  if (!inner) throw new CompileError('latexml produced empty output')
  return styles ? `${styles}\n${inner}` : inner
}

export class WasmLatexmlCompiler implements CompilePort {
  private readonly engine: LatexmlEngine | undefined

  constructor(deps: WasmLatexmlCompilerDeps = {}) {
    this.engine = deps.engine
  }

  supports(kind: CompileKind): boolean {
    return kind === 'table' && this.engine !== undefined
  }

  async tableToHtml(latex: string): Promise<string> {
    if (!this.engine) {
      throw new CompileError(
        'WASM latexml engine is not built yet; the table Compile adapter is a ' +
          'scaffold. See engine/README.md (roadmap phases P0-P4).',
      )
    }
    let raw: string
    try {
      raw = await this.engine.convert(buildTableDocument(latex))
    } catch (cause) {
      throw new CompileError(`latexml compile failed: ${(cause as Error).message}`, { cause })
    }
    return finalizeHtml(raw)
  }
}
