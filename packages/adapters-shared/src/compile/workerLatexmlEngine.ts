/**
 * Worker-hosted LatexmlEngine: the main-thread half. Contract: see
 * workerLatexmlEngine.md.
 *
 * The WASM latexml conversion is synchronous and multi-second on the first (boot)
 * call, so hosting it on the UI thread would freeze the editor. This proxies each
 * `convert` to a Web Worker that owns the Perl interpreter (see the worker half at
 * web-shell/public/latexml/worker.js) and correlates replies by id. The worker
 * serializes conversions internally (one non-re-entrant interpreter), so this side
 * needs no queue — just request/response matching.
 *
 * Bundler-agnostic like `createBrowserLatexmlEngine`: the caller constructs the
 * Worker (owning the asset URLs its bundler produced) and hands it in, already sent
 * its `init` message.
 */
import type { LatexmlEngine } from './wasmLatexmlCompiler'

/** The minimal Worker surface this proxy uses (DOM-lib-free for portability/tests). */
export interface LatexmlWorker {
  postMessage(message: unknown): void
  addEventListener(type: 'message', listener: (event: { data: unknown }) => void): void
}

/** A reply from the worker: the compiled page, or a surfaced error, tagged by request id. */
interface WorkerReply {
  id?: number
  html?: string
  error?: string
}

export function createWorkerLatexmlEngine(worker: LatexmlWorker): LatexmlEngine {
  let seq = 0
  const pending = new Map<
    number,
    { resolve: (html: string) => void; reject: (err: Error) => void }
  >()

  worker.addEventListener('message', (event) => {
    const data = event.data as WorkerReply | null
    if (!data || typeof data.id !== 'number') return
    const entry = pending.get(data.id)
    if (!entry) return
    pending.delete(data.id)
    if (typeof data.error === 'string') entry.reject(new Error(data.error))
    else entry.resolve(data.html ?? '')
  })

  return {
    convert(latexDocument: string): Promise<string> {
      const id = ++seq
      return new Promise<string>((resolve, reject) => {
        pending.set(id, { resolve, reject })
        worker.postMessage({ type: 'convert', id, tex: latexDocument })
      })
    },
  }
}
