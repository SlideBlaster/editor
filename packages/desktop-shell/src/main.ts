/**
 * Desktop-shell entry. Contract: see main.md.
 *
 * The Tauri shell is a thin wrapper: it mounts the shared editor app
 * (`@slideblaster/app`) into the webview. Native port adapters (filesystem storage,
 * native git, keychain auth, Tauri print/export) will be built here — over
 * `@tauri-apps/api` / `@slideblaster/adapters-native` — and passed to `createApp` as
 * they land (M5). None are wired yet; the app runs the bundled in-memory sample,
 * identical to the web shell.
 */
import { createApp } from '@slideblaster/app'

const root = document.getElementById('app')
if (!root) throw new Error('missing #app root element')
createApp(root, { shellTag: 'desktop · M5' })
