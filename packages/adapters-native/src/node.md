# native node bindings (node.ts)

The Node binding for the native adapters — the **only** file in the package that imports
`node:*`. It supplies the three runtime-specific pieces the runtime-agnostic adapters need
under Node, and a convenience workspace factory. Keeping every `node:*` import here is what
lets the adapter classes bundle into the Tauri webview (which imports the classes but never
this file).

## Contract

- `nodeFs` — the `node:fs` module as an isomorphic-git `PromiseFsClient`.
- `nodeHttp` — isomorphic-git's Node HTTP client, for remote git over Node.
- `nodeWatch` — a `NativeWatch` over `node:fs` `watch`: recursive where the platform allows
  it (else one directory level), raw events debounced and resolved against the live
  filesystem into a single create/update/delete FileEvent with a POSIX-relative path; a
  snapshot seeded at subscription distinguishes first-create from update and enables delete
  detection for pre-existing files. The returned `Unsubscribe` closes the watcher.
- `createNodeWorkspace(dir)` — `createNativeWorkspace` bound to `nodeFs` + `nodeWatch` +
  `nodeHttp`. What the CLI and tests use.

## Relations

- Binds the adapters in workspace.md / storage/nativeFsStorageAdapter.md /
  git/nativeGitAdapter.md to Node. The desktop peer is `desktop-shell/src/tauriFs.md`.
