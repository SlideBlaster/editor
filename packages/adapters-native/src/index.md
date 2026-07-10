# adapters-native

Native (desktop) port adapters — the on-disk peer of `adapters-browser`.

`createNativeWorkspace({ dir })` returns a `{ storage, git }` pair over ONE real
directory, mirroring `createBrowserWorkspace`: the shared directory is the
load-bearing seam (git sees storage writes), and first run does `git init` (branch
`main`) so a working copy exists offline — no remote, no GitHub, no credentials.

- `NativeFsStorageAdapter` — `StoragePort` over the filesystem (default `node:fs`),
  paths working-copy-relative and POSIX; `watch` observes external changes too.
- `NativeGitAdapter` — `GitPort` via isomorphic-git; `fs`/`http` are injectable
  (default `node:fs` + isomorphic-git's node HTTP), so no external git binary and no
  CORS proxy.

Runtime note: the default binding is `node:fs`. Running inside the Tauri webview
(which has no Node) requires injecting a Tauri-fs-backed `FsClient` — see the
desktop-shell wiring. `push`/`pull` are integration-only (a live remote + a scoped
token).
