/// <reference types="vite/client" />
/**
 * Web-shell entry. Contract: see main.md.
 *
 * The browser shell is a thin wrapper: it builds the browser adapters — the
 * IndexedDB working copy (storage + git over one shared fs) and the dev auth
 * stand-in — plus the WASM latexml Compile port (tables), and mounts the shared
 * editor app with those ports. If the working copy fails to open (e.g. IndexedDB
 * unavailable), it falls back to the in-memory sample so the editor still runs.
 */
import { createApp } from '@slideblaster/app'
import {
  createBrowserWorkspace,
  createBrowserAuthAdapter,
  DevAuthAdapter,
} from '@slideblaster/adapters-browser'
import { WasmLatexmlCompiler, createWorkerLatexmlEngine } from '@slideblaster/adapters-shared'
import type { AuthPort, CompilePort } from '@slideblaster/editor'
// The emscripten build lives once (Git LFS) in adapters-shared; `?url` hands Vite the
// asset URLs to bundle without transforming the 220 KB CJS glue or the 20 MB payload.
import perlJsUrl from '../../adapters-shared/src/compile/engine/dist/perl-web.js?url'
import perlWasmUrl from '../../adapters-shared/src/compile/engine/dist/perl-web.wasm?url'
import perlDataUrl from '../../adapters-shared/src/compile/engine/dist/perl-web.data?url'

const root = document.getElementById('app')
if (!root) throw new Error('missing #app root element')

/**
 * The Compile port over a Web Worker running WASM latexml. The worker is a static
 * classic script (public/latexml/worker.js) so it can `importScripts` the glue; we
 * hand it the bundled asset URLs. Returns undefined if Workers are unavailable —
 * tables then render as "render pending" placeholders (graceful degrade).
 */
function createCompilePort(): CompilePort | undefined {
  try {
    const worker = new Worker('/latexml/worker.js')
    worker.postMessage({
      type: 'init',
      jsUrl: perlJsUrl,
      wasmUrl: perlWasmUrl,
      dataUrl: perlDataUrl,
    })
    return new WasmLatexmlCompiler({ engine: createWorkerLatexmlEngine(worker) })
  } catch (err) {
    console.error('latexml worker unavailable; tables render as placeholders', err)
    return undefined
  }
}

/**
 * Pick the Auth port. With VITE_SB_AUTH_URL set, use the real browser adapter
 * against that Auth service — `/` means "this origin" (local dev through the Vite
 * proxy to the auth-stub). Unset, fall back to the offline DevAuthAdapter (instant
 * local identity; an optional PAT enables manual remote git).
 */
async function createAuth(): Promise<AuthPort> {
  const authUrl = import.meta.env.VITE_SB_AUTH_URL as string | undefined
  if (authUrl) {
    return createBrowserAuthAdapter({ baseUrl: authUrl === '/' ? '' : authUrl })
  }
  return new DevAuthAdapter({ tokenValue: import.meta.env.VITE_SB_DEV_PAT as string | undefined })
}

async function boot(el: HTMLElement): Promise<void> {
  const compile = createCompilePort()
  try {
    const { storage, git } = await createBrowserWorkspace({
      corsProxy: import.meta.env.VITE_SB_GIT_PROXY as string | undefined,
    })
    const auth = await createAuth()
    createApp(el, { shellTag: 'web-shell · M4', ports: { storage, git, auth, compile } })
  } catch (err) {
    console.error('working copy unavailable, running in memory', err)
    createApp(el, { shellTag: 'web-shell · M4 (in-memory)' })
  }
}

void boot(root)
