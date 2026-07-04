/**
 * Cloudflare Worker entry for the git proxy. Contract: see worker.md.
 *
 * The production runtime target (roadmap Track 0). All logic lives in the
 * runtime-agnostic handler; the Worker is a thin adapter.
 */
import { handleProxy } from './handler'

export default {
  fetch(request: Request): Promise<Response> {
    return handleProxy(request)
  },
}
