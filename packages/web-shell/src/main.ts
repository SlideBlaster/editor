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
import { createApp, renderHome, createProjectRegistry } from '@slideblaster/app'
import {
  createBrowserWorkspace,
  createBrowserAuthAdapter,
  DevAuthAdapter,
} from '@slideblaster/adapters-browser'
import {
  ANNOTATION_BINDING,
  WasmLatexmlCompiler,
  createWorkerLatexmlEngine,
} from '@slideblaster/adapters-shared'
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
      binding: ANNOTATION_BINDING, // stamp compiled table cells with data-sbx/y
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

// Which project is open this tab-session; absent -> land on the projects page.
// Reload-based routing keeps teardown trivial (createApp wires document-level
// listeners): every hop is a fresh page, no leaked state between project/editor.
const OPEN_KEY = 'slideblaster.open-project'
const registry = createProjectRegistry()

function openProjectId(): string | null {
  try {
    return sessionStorage.getItem(OPEN_KEY)
  } catch {
    return null
  }
}

function setOpenProject(id: string | null): void {
  try {
    if (id) sessionStorage.setItem(OPEN_KEY, id)
    else sessionStorage.removeItem(OPEN_KEY)
  } catch {
    // sessionStorage unavailable: routing falls back to always-landing.
  }
}

/** The projects landing: create opens immediately; open/delete route via reload. */
function showHome(el: HTMLElement): void {
  renderHome(el, {
    projects: registry.list(),
    onOpen: (id) => {
      setOpenProject(id)
      location.reload()
    },
    onCreate: (name) => {
      const project = registry.create(name)
      setOpenProject(project.id)
      location.reload()
    },
    onDelete: (id) => {
      registry.remove(id)
      showHome(el)
    },
  })
}

/** Open one project into the editor, scoped to its own working-copy directory. */
async function openProject(el: HTMLElement, id: string): Promise<void> {
  const project = registry.get(id)
  if (!project) {
    // Stale open pointer (e.g. deleted elsewhere): fall back to the landing.
    setOpenProject(null)
    showHome(el)
    return
  }
  registry.touch(id)
  const compile = createCompilePort()
  const exit = (): void => {
    setOpenProject(null)
    location.reload()
  }
  try {
    const { storage, git } = await createBrowserWorkspace({
      dir: `/projects/${id}`,
      corsProxy: import.meta.env.VITE_SB_GIT_PROXY as string | undefined,
    })
    const auth = await createAuth()
    createApp(el, {
      shellTag: `web-shell · ${project.name}`,
      ports: { storage, git, auth, compile },
      onExitToProjects: exit,
    })
  } catch (err) {
    console.error('working copy unavailable, running in memory', err)
    createApp(el, { shellTag: 'web-shell · M4 (in-memory)', onExitToProjects: exit })
  }
}

async function boot(el: HTMLElement): Promise<void> {
  const id = openProjectId()
  if (id) await openProject(el, id)
  else showHome(el)
}

void boot(root)
