/**
 * @slideblaster/adapters-native public surface. Contract: see index.md.
 *
 * The native (desktop) working copy: Storage + Git over one real on-disk directory
 * (createNativeWorkspace), the native peer of the browser working copy. The `fs`
 * binding is injected, so this surface is runtime-agnostic and bundles into the Tauri
 * webview; the `node:fs` binding lives in ./node (imported by Node consumers only).
 */
export { NativeFsStorageAdapter } from './storage/nativeFsStorageAdapter'
export type { NativeFsStorageAdapterOptions, NativeWatch } from './storage/nativeFsStorageAdapter'
export { NativeGitAdapter } from './git/nativeGitAdapter'
export type { NativeGitAdapterOptions } from './git/nativeGitAdapter'
export { createNativeWorkspace } from './workspace'
export type { NativeWorkspace, NativeWorkspaceOptions } from './workspace'
// Re-exported so a shell can type its injected filesystem/HTTP bindings without a
// direct isomorphic-git dependency.
export type { FsClient, HttpClient, PromiseFsClient } from 'isomorphic-git'
