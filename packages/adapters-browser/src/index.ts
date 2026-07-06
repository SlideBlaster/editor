/**
 * @slideblaster/adapters-browser public surface. Contract: see index.md.
 *
 * M3: the browser working copy — Storage + Git over one shared IndexedDB fs
 * (createBrowserWorkspace) plus the dev Auth adapter. Collab, Compile, and
 * Export adapters attach here as they land.
 */
export { IsomorphicGitAdapter } from './git/isomorphicGitAdapter'
export type { IsomorphicGitAdapterDeps } from './git/isomorphicGitAdapter'
export { createBrowserGitAdapter } from './git/browserGit'
export type { BrowserGitOptions } from './git/browserGit'
export { FsStorageAdapter } from './storage/fsStorageAdapter'
export type { FsStorageAdapterOptions, PromiseFs } from './storage/fsStorageAdapter'
export { createBrowserWorkspace } from './workspace'
export type { BrowserWorkspace, BrowserWorkspaceOptions } from './workspace'
export { DevAuthAdapter } from './auth/devAuthAdapter'
export type { DevAuthOptions } from './auth/devAuthAdapter'
