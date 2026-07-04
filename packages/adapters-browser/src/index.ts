/**
 * @slideblaster/adapters-browser public surface. Contract: see index.md.
 *
 * Track-0 spike: the browser Git port. Other browser adapters (Storage, Collab,
 * Compile, Export) attach here as they land.
 */
export { IsomorphicGitAdapter } from './git/isomorphicGitAdapter'
export type { IsomorphicGitAdapterDeps } from './git/isomorphicGitAdapter'
export { createBrowserGitAdapter } from './git/browserGit'
export type { BrowserGitOptions } from './git/browserGit'
