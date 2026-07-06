/**
 * Browser workspace factory. Contract: see workspace.md.
 *
 * Builds the Storage and Git adapters over ONE LightningFS instance and one
 * working-copy dir, and bootstraps the local repository on first run. Sharing the
 * filesystem is the load-bearing seam: git status/commit must see storage writes.
 */
import { Buffer } from 'buffer'
import LightningFS from '@isomorphic-git/lightning-fs'
import http from 'isomorphic-git/http/web'
import type { FsClient } from 'isomorphic-git'
import { IsomorphicGitAdapter } from './git/isomorphicGitAdapter'
import { FsStorageAdapter, type PromiseFs } from './storage/fsStorageAdapter'

// isomorphic-git assumes a Node-style global Buffer, which browsers lack.
// Install the polyfill once here, where the browser git stack is assembled.
if (typeof globalThis.Buffer === 'undefined') {
  globalThis.Buffer = Buffer
}

export interface BrowserWorkspaceOptions {
  /** IndexedDB database name backing the working copy. */
  fsName?: string
  /** Working-copy root inside the browser FS. */
  dir?: string
  /** URL of the first-party CORS proxy (needed only for remote git, M4). */
  corsProxy?: string
}

export interface BrowserWorkspace {
  storage: FsStorageAdapter
  git: IsomorphicGitAdapter
}

const DEFAULT_DIR = '/repo'

/**
 * Create the storage+git pair over a shared IndexedDB filesystem. On first run
 * (no repository at `dir`) the directory is created and `git init` run, so the
 * caller always receives a working copy with local history available — offline,
 * no remote, no credentials (M3).
 */
export async function createBrowserWorkspace(
  options: BrowserWorkspaceOptions = {},
): Promise<BrowserWorkspace> {
  const fs = new LightningFS(options.fsName ?? 'slideblaster')
  const dir = options.dir ?? DEFAULT_DIR
  const pfs = fs.promises as unknown as PromiseFs

  const storage = new FsStorageAdapter({ fs: pfs, dir })
  const git = new IsomorphicGitAdapter({
    fs: fs as unknown as FsClient,
    http,
    corsProxy: options.corsProxy,
    dir,
  })

  await mkdirIfMissing(pfs, dir)
  if (!(await exists(pfs, `${dir}/.git`))) await git.init(dir)

  return { storage, git }
}

async function exists(fs: PromiseFs, path: string): Promise<boolean> {
  try {
    await fs.stat(path)
    return true
  } catch {
    return false
  }
}

async function mkdirIfMissing(fs: PromiseFs, path: string): Promise<void> {
  try {
    await fs.mkdir(path)
  } catch (error) {
    const code =
      error && typeof error === 'object' && 'code' in error
        ? (error as { code: unknown }).code
        : undefined
    if (code !== 'EEXIST') throw error
  }
}
