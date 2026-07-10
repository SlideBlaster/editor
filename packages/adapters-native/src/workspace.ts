/**
 * Native workspace factory. Contract: see workspace.md.
 *
 * The native peer of createBrowserWorkspace: the Storage and Git adapters over ONE
 * real on-disk directory. Sharing that directory is the load-bearing seam — git
 * status/commit must see storage writes, and a git checkout/pull must change what
 * storage reads. On first run the directory is created and a local repository
 * initialised (branch `main`), so the caller always receives a working copy with
 * local history available offline, with no remote and no credentials.
 *
 * Runtime-agnostic: the `fs` (and optional `watch`/`http`) bindings are injected, so
 * this same factory builds a Node working copy (see ./node `createNodeWorkspace`) and
 * a desktop-webview working copy (a Tauri-fs client). It has no Node import.
 */
import type { HttpClient, PromiseFsClient } from 'isomorphic-git'
import { NativeGitAdapter } from './git/nativeGitAdapter'
import { NativeFsStorageAdapter, type NativeWatch } from './storage/nativeFsStorageAdapter'
import { errorCode } from './paths'

export interface NativeWorkspaceOptions {
  /** Working-copy root on the OS filesystem. */
  dir: string
  /** Filesystem binding shared by storage and git. See ./node for the `node:fs` one. */
  fs: PromiseFsClient
  /** Optional external-change watcher for storage (best-effort). */
  watch?: NativeWatch
  /** Optional HTTP client for remote git ops (clone/pull/push). */
  http?: HttpClient
}

export interface NativeWorkspace {
  storage: NativeFsStorageAdapter
  git: NativeGitAdapter
}

/**
 * Create the storage+git pair over one shared directory. On first run (no repository
 * at `dir`) the directory is created and `git init` (branch `main`) is run, so the
 * caller always receives a working copy with local history available — offline, no
 * remote, no credentials. An existing repository is left untouched.
 */
export async function createNativeWorkspace(
  options: NativeWorkspaceOptions,
): Promise<NativeWorkspace> {
  const root = options.dir.replace(/\/+$/, '')
  const storage = new NativeFsStorageAdapter({ dir: root, fs: options.fs, watch: options.watch })
  const git = new NativeGitAdapter({ dir: root, fs: options.fs, http: options.http })

  await ensureDirAbs(options.fs, root)
  if (!(await exists(options.fs, `${root}/.git`))) await git.init(root)

  return { storage, git }
}

/** mkdir -p an absolute path level by level (portable across FsClients without recursive mkdir). */
async function ensureDirAbs(fs: PromiseFsClient, absDir: string): Promise<void> {
  let cur = absDir.startsWith('/') ? '' : '.'
  for (const seg of absDir.split('/').filter(Boolean)) {
    cur = cur === '' ? `/${seg}` : cur === '.' ? seg : `${cur}/${seg}`
    try {
      await fs.promises.mkdir(cur)
    } catch (error) {
      if (errorCode(error) !== 'EEXIST') throw error
    }
  }
}

async function exists(fs: PromiseFsClient, path: string): Promise<boolean> {
  try {
    await fs.promises.stat(path)
    return true
  } catch {
    return false
  }
}
