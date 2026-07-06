/**
 * Browser LatexmlEngine: drives the WASM build of LaTeXML (engine/dist/perl-web.*)
 * in the browser / a Web Worker. The emscripten module is instantiated ONCE
 * (wasm compiled + the ~12.7 MB LaTeXML filesystem preloaded into MEMFS), then
 * reused for every conversion — each table is a fresh `callMain` against the
 * already-loaded runtime, so only the first conversion pays the boot cost.
 *
 * Conversions are serialized: a single Perl interpreter instance is not
 * re-entrant, so overlapping `callMain` calls would corrupt state.
 *
 * Bundler-agnostic: the caller supplies `createPerlModule` (the MODULARIZE
 * factory from perl-web.js) and a `locateFile` that resolves perl-web.wasm /
 * perl-web.data URLs for its asset pipeline. Best hosted inside a Worker so the
 * synchronous conversion never blocks the UI thread.
 */
import type { LatexmlEngine } from './wasmLatexmlCompiler'
import { installTableAnnotation } from './tableAnnotation'

/** The emscripten runtime surface this engine relies on (subset of Module). */
export interface PerlModule {
  callMain(args: string[]): number
  FS: {
    writeFile(path: string, data: string): void
    readFile(path: string, opts: { encoding: 'utf8' }): string
    unlink(path: string): void
  }
  ENV: Record<string, string>
}

export type PerlModuleFactory = (moduleArg: Record<string, unknown>) => Promise<PerlModule>

export interface BrowserLatexmlEngineOptions {
  /** The `createPerlModule` factory exported by perl-web.js. */
  createPerlModule: PerlModuleFactory
  /** Resolve a runtime asset (`perl-web.wasm`, `perl-web.data`) to a URL. */
  locateFile?: (path: string) => string
}

// @INC inside the preloaded MEMFS (mounted at /sb by --preload-file). Order:
// patched overlay first, then perl core, the XS pure-perl halves, then LaTeXML.
const INC_ARGS = [
  '/sb/overlay',
  '/sb/lib',
  '/sb/xml-libxml',
  '/sb/xml-libxslt',
  '/sb/perl5',
].flatMap((p) => ['-I', p])
const DRIVER = '/sb/driver.pl'
const IN = '/in.tex'
const OUT = '/out.html'

export function createBrowserLatexmlEngine(opts: BrowserLatexmlEngineOptions): LatexmlEngine {
  let modulePromise: Promise<PerlModule> | undefined
  let queue: Promise<unknown> = Promise.resolve()

  const boot = (): Promise<PerlModule> => {
    if (!modulePromise) {
      modulePromise = opts
        .createPerlModule({
          noInitialRun: true,
          ...(opts.locateFile ? { locateFile: opts.locateFile } : {}),
          print: () => {},
          printErr: () => {},
        })
        .then((m) => {
          m.ENV.PERL_HASH_SEED = '0' // deterministic output
          installTableAnnotation(m.FS) // stamp compiled cells with data-sbx/y (best-effort)
          return m
        })
    }
    return modulePromise
  }

  const convertOnce = async (latexDocument: string): Promise<string> => {
    const m = await boot()
    m.FS.writeFile(IN, latexDocument)
    try {
      m.FS.unlink(OUT)
    } catch {
      // no prior output
    }
    const code = m.callMain([...INC_ARGS, DRIVER, IN, OUT])
    let html: string
    try {
      html = m.FS.readFile(OUT, { encoding: 'utf8' })
    } catch {
      throw new Error(`WASM latexml produced no output (exit ${code})`)
    }
    if (!html) throw new Error(`WASM latexml produced empty output (exit ${code})`)
    return html
  }

  return {
    convert(latexDocument: string): Promise<string> {
      // Chain onto the queue so conversions never overlap on the single instance.
      const result = queue.then(() => convertOnce(latexDocument))
      queue = result.catch(() => undefined)
      return result
    },
  }
}
