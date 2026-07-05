/**
 * Web-shell entry. Contract: see main.md.
 *
 * The browser shell is a thin wrapper: it mounts the shared editor app
 * (`@slideblaster/app`) into the page. Browser port adapters (storage, git, auth,
 * export) will be built here and passed to `createApp` as they land (M3+); none are
 * wired yet.
 */
import { createApp } from '@slideblaster/app'

const root = document.getElementById('app')
if (!root) throw new Error('missing #app root element')
createApp(root, { shellTag: 'web-shell · M2' })
