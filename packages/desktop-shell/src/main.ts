/**
 * Desktop-shell entry. Contract: see main.md.
 *
 * The Tauri shell is a thin wrapper over the shared editor app (`@slideblaster/app`),
 * differing from the web shell only in its adapters and its landing screen. Instead of
 * browser projects it opens a REAL directory the user picks, mounts it as a native
 * working copy (Storage + Git over `node:fs`'s desktop peer — a Tauri-fs client — via
 * `createNativeWorkspace`), and checks for an app self-update on startup.
 *
 * Local-first by design: opening a folder needs no account and no GitHub; the working
 * copy gets a local git repo (branch `main`) with no remote. A remote can be added later
 * from the source-control panel. The app binary's updates (GitHub Releases) are a wholly
 * separate channel from the user's decks.
 */
import { createApp } from '@slideblaster/app'
import { createNativeWorkspace } from '@slideblaster/adapters-native'
import { DevAuthAdapter } from '@slideblaster/adapters-browser'
import { open as openFolderDialog } from '@tauri-apps/plugin-dialog'
import { tauriFs, tauriWatch } from './tauriFs'
import { checkForUpdatesOnStartup } from './update'

const root = document.getElementById('app')
if (!root) throw new Error('missing #app root element')

// Which directory to open this launch, plus a short recents list — both are just paths
// in localStorage. Reload-based routing keeps teardown trivial (createApp wires
// document-level listeners): every hop is a fresh page, like the web shell.
const LAST_KEY = 'slideblaster.desktop.last-dir'
const RECENTS_KEY = 'slideblaster.desktop.recents'
const RECENTS_MAX = 8

function readRecents(): string[] {
  try {
    const parsed: unknown = JSON.parse(localStorage.getItem(RECENTS_KEY) ?? '[]')
    return Array.isArray(parsed) ? parsed.filter((d): d is string => typeof d === 'string') : []
  } catch {
    return []
  }
}

function writeRecents(list: string[]): void {
  try {
    localStorage.setItem(RECENTS_KEY, JSON.stringify(list.slice(0, RECENTS_MAX)))
  } catch {
    // localStorage unavailable: recents simply do not persist.
  }
}

function rememberDir(dir: string): void {
  writeRecents([dir, ...readRecents().filter((d) => d !== dir)])
}

function forgetDir(dir: string): void {
  writeRecents(readRecents().filter((d) => d !== dir))
}

function lastDir(): string | null {
  try {
    return localStorage.getItem(LAST_KEY)
  } catch {
    return null
  }
}

function setLastDir(dir: string | null): void {
  try {
    if (dir) localStorage.setItem(LAST_KEY, dir)
    else localStorage.removeItem(LAST_KEY)
  } catch {
    // Ignore: routing falls back to always-landing.
  }
}

/** Last path segment of an OS path, for a friendly window/shell label. */
function basename(dir: string): string {
  const parts = dir.replace(/[/\\]+$/, '').split(/[/\\]/)
  return parts[parts.length - 1] || dir
}

/** Native directory picker; returns the chosen absolute path, or null if cancelled. */
async function pickFolder(): Promise<string | null> {
  const picked = await openFolderDialog({
    directory: true,
    multiple: false,
    title: 'Open a SlideBlaster folder',
  })
  return typeof picked === 'string' ? picked : null
}

/** Remember `dir` as the open+recent target and reload into it. */
function openDir(dir: string): void {
  setLastDir(dir)
  rememberDir(dir)
  location.reload()
}

/** Minimal landing: an Open Folder button plus a recents list. */
function showHome(el: HTMLElement): void {
  injectHomeStyles()
  el.replaceChildren()

  const wrap = document.createElement('div')
  wrap.className = 'desktop-home'

  const title = document.createElement('h1')
  title.textContent = 'SlideBlaster'
  const blurb = document.createElement('p')
  blurb.textContent =
    'Open a folder on your computer to use it as a local, git-backed SlideBlaster working copy. No account or GitHub required.'

  const openBtn = document.createElement('button')
  openBtn.type = 'button'
  openBtn.className = 'desktop-open'
  openBtn.textContent = 'Open Folder…'
  openBtn.addEventListener('click', () => {
    void pickFolder().then((dir) => {
      if (dir) openDir(dir)
    })
  })

  wrap.append(title, blurb, openBtn)

  const recents = readRecents()
  if (recents.length) {
    const heading = document.createElement('h2')
    heading.textContent = 'Recent'
    const list = document.createElement('ul')
    list.className = 'desktop-recents'
    for (const dir of recents) {
      const item = document.createElement('li')

      const open = document.createElement('button')
      open.type = 'button'
      open.className = 'recent-open'
      open.textContent = basename(dir)
      open.title = dir
      open.addEventListener('click', () => openDir(dir))

      const remove = document.createElement('button')
      remove.type = 'button'
      remove.className = 'recent-remove'
      remove.textContent = 'Remove'
      remove.setAttribute('aria-label', `Remove ${dir} from recent folders`)
      remove.addEventListener('click', () => {
        forgetDir(dir)
        showHome(el)
      })

      item.append(open, remove)
      list.append(item)
    }
    wrap.append(heading, list)
  }

  el.append(wrap)
}

/** Open `dir` as a native working copy and mount the shared editor onto it. */
async function mount(el: HTMLElement, dir: string): Promise<void> {
  const { storage, git } = await createNativeWorkspace({ dir, fs: tauriFs, watch: tauriWatch })
  const auth = new DevAuthAdapter()
  createApp(el, {
    shellTag: `desktop · ${basename(dir)}`,
    ports: { storage, git, auth },
    onExitToProjects: () => {
      setLastDir(null)
      location.reload()
    },
  })
}

async function boot(el: HTMLElement): Promise<void> {
  void checkForUpdatesOnStartup() // fire-and-forget; never blocks the editor

  const dir = lastDir()
  if (!dir) {
    showHome(el)
    return
  }
  try {
    await mount(el, dir)
  } catch (err) {
    console.error('failed to open the working copy; returning to the picker', err)
    setLastDir(null)
    showHome(el)
  }
}

/** A small, self-contained stylesheet for the landing (the editor injects its own). */
function injectHomeStyles(): void {
  if (document.getElementById('desktop-home-styles')) return
  const style = document.createElement('style')
  style.id = 'desktop-home-styles'
  style.textContent = `
    .desktop-home { max-width: 40rem; margin: 12vh auto; padding: 0 1.5rem;
      font: 16px/1.5 system-ui, sans-serif; }
    .desktop-home h1 { font-size: 2rem; margin: 0 0 .25rem; }
    .desktop-home p { color: #444; margin: 0 0 1.25rem; }
    .desktop-open { font: inherit; padding: .6rem 1.1rem; border-radius: .5rem;
      border: 1px solid #2b6cb0; background: #2b6cb0; color: #fff; cursor: pointer; }
    .desktop-open:hover { background: #245a94; }
    .desktop-home h2 { font-size: .85rem; text-transform: uppercase; letter-spacing: .04em;
      color: #666; margin: 2rem 0 .5rem; }
    .desktop-recents { list-style: none; margin: 0; padding: 0; }
    .desktop-recents li { display: flex; align-items: center; justify-content: space-between;
      gap: 1rem; padding: .35rem 0; border-bottom: 1px solid #eee; }
    .recent-open { font: inherit; background: none; border: 0; color: #2b6cb0; cursor: pointer;
      padding: 0; text-align: left; }
    .recent-open:hover { text-decoration: underline; }
    .recent-remove { font: inherit; font-size: .8rem; background: none; border: 0; color: #999;
      cursor: pointer; }
    .recent-remove:hover { color: #c00; }
  `
  document.head.append(style)
}

void boot(root)
