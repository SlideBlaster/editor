/// <reference types="vite/client" />
/**
 * Web-shell entry. Contract: see main.md.
 *
 * The browser shell is a thin wrapper: it builds the browser adapters — the
 * IndexedDB working copy (storage + git over one shared fs) and the dev auth
 * stand-in — and mounts the shared editor app with those ports. If the working
 * copy fails to open (e.g. IndexedDB unavailable), it falls back to the
 * in-memory sample so the editor still runs.
 */
import { createApp } from '@slideblaster/app'
import { createBrowserWorkspace, DevAuthAdapter } from '@slideblaster/adapters-browser'

const root = document.getElementById('app')
if (!root) throw new Error('missing #app root element')

async function boot(el: HTMLElement): Promise<void> {
  try {
    const { storage, git } = await createBrowserWorkspace({
      corsProxy: import.meta.env.VITE_SB_GIT_PROXY as string | undefined,
    })
    const auth = new DevAuthAdapter({
      tokenValue: import.meta.env.VITE_SB_DEV_PAT as string | undefined,
    })
    createApp(el, { shellTag: 'web-shell · M3', ports: { storage, git, auth } })
  } catch (err) {
    console.error('working copy unavailable, running in memory', err)
    createApp(el, { shellTag: 'web-shell · M3 (in-memory)' })
  }
}

void boot(root)
