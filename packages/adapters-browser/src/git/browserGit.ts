/**
 * Browser factory for the git adapter. Contract: see browserGit.md.
 *
 * Wires an IndexedDB-backed LightningFS working copy and isomorphic-git's web http
 * client into the injectable adapter, aimed at the first-party CORS proxy.
 */
import LightningFS from '@isomorphic-git/lightning-fs'
import http from 'isomorphic-git/http/web'
import type { FsClient } from 'isomorphic-git'
import { IsomorphicGitAdapter } from './isomorphicGitAdapter'

export interface BrowserGitOptions {
  /** URL of the first-party CORS proxy. */
  corsProxy: string
  /** Working-copy root inside the browser FS. */
  dir?: string
  /** IndexedDB database name for the LightningFS working copy. */
  fsName?: string
}

export function createBrowserGitAdapter(options: BrowserGitOptions): IsomorphicGitAdapter {
  const fs = new LightningFS(options.fsName ?? 'slideblaster')
  return new IsomorphicGitAdapter({
    fs: fs as unknown as FsClient,
    http,
    corsProxy: options.corsProxy,
    dir: options.dir,
  })
}
