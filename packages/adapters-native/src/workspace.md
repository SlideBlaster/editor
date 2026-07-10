# createNativeWorkspace

The shells' one-stop factory for a local working copy: the Storage and Git adapters over
**one shared on-disk directory**. The native peer of `createBrowserWorkspace`.

## Contract

- `createNativeWorkspace({ dir, fs, watch?, http? }) -> Promise<{ storage, git }>`.
- **Runtime-agnostic.** The `fs` binding (an isomorphic-git `PromiseFsClient`), plus the
  optional `watch`/`http`, are injected, so this same factory builds a Node working copy
  and a desktop-webview working copy. It has no `node:*` import. The Node convenience
  wrapper `createNodeWorkspace(dir)` in [node.md](./node.md) wires the `node:fs` bindings;
  the desktop shell wires a Tauri-fs binding (`desktop-shell/src/tauriFs.md`).
- **Shared-dir invariant:** both adapters operate on the same directory. A `storage.write`
  is immediately visible to `git.status()`/`stage`; a git `checkout`/`pull` changes the
  files storage reads. Building the two adapters over different directories silently breaks
  the product — use this factory, not the individual constructors, in shells.
- **Bootstrap:** on first run the directory is created level by level (portable `mkdir -p`
  over the injected fs) and `git init` (branch `main`) is run, so the returned workspace
  always has local history available offline with no remote and no credentials. An existing
  repository (`.git` present) is left untouched.
- Offline only: a remote attaches later via the git adapter's `clone`/`push`/`pull`.

## Relations

- Wraps `NativeFsStorageAdapter` (storage/nativeFsStorageAdapter.md) and `NativeGitAdapter`
  (git/nativeGitAdapter.md); node bindings in [node.md](./node.md); pure path helpers in
  [paths.md](./paths.md). Mirrors `createBrowserWorkspace`
  (../../adapters-browser/src/workspace.md). Consumed by `desktop-shell/src/main.md`.
