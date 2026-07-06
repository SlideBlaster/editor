/**
 * The worker proxy must correlate concurrent conversions by id (the compiler fires
 * tables in parallel) and turn a worker error reply into a rejected promise. Driven
 * with a fake worker — no real Worker, no WASM.
 */
import { describe, expect, it } from 'vitest'
import { createWorkerLatexmlEngine, type LatexmlWorker } from './workerLatexmlEngine'

/** A fake worker that records posts and lets the test push replies back. */
function fakeWorker() {
  const posts: Array<{ type: string; id: number; tex: string }> = []
  let listener: ((event: { data: unknown }) => void) | undefined
  const worker: LatexmlWorker = {
    postMessage: (msg) => posts.push(msg as { type: string; id: number; tex: string }),
    addEventListener: (_type, l) => {
      listener = l
    },
  }
  return { worker, posts, reply: (data: unknown) => listener?.({ data }) }
}

describe('createWorkerLatexmlEngine', () => {
  it('resolves each convert with the reply carrying its id, out of order', async () => {
    const { worker, posts, reply } = fakeWorker()
    const engine = createWorkerLatexmlEngine(worker)

    const a = engine.convert('doc-A')
    const b = engine.convert('doc-B')
    expect(posts).toEqual([
      { type: 'convert', id: 1, tex: 'doc-A' },
      { type: 'convert', id: 2, tex: 'doc-B' },
    ])

    // Reply to B first: correlation is by id, not arrival order.
    reply({ id: 2, html: 'HTML-B' })
    reply({ id: 1, html: 'HTML-A' })
    expect(await a).toBe('HTML-A')
    expect(await b).toBe('HTML-B')
  })

  it('rejects when the worker returns an error reply', async () => {
    const { worker, reply } = fakeWorker()
    const engine = createWorkerLatexmlEngine(worker)
    const p = engine.convert('bad')
    reply({ id: 1, error: 'boom' })
    await expect(p).rejects.toThrow('boom')
  })

  it('ignores stray replies with no matching pending request', async () => {
    const { worker, reply } = fakeWorker()
    const engine = createWorkerLatexmlEngine(worker)
    reply({ id: 999, html: 'ghost' }) // must not throw
    const p = engine.convert('doc')
    reply({ id: 1, html: 'ok' })
    expect(await p).toBe('ok')
  })
})
