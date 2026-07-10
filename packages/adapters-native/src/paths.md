# native paths (paths.ts)

Pure, dependency-free path helpers shared by the native adapters. No `node:*` import, so
every file that uses them bundles unchanged into the Tauri webview.

## Contract

- `normalize(path)` — a working-copy-relative path to canonical POSIX: drops `.`/empty
  segments, tolerates leading `./` or `/`, and **throws on any `..`** (the escape guard the
  Storage port relies on).
- `posixJoin(base, name)` / `posixDirname(rel)` — join a single child / take the parent,
  POSIX-only (`''` is the root).
- `errorCode(error)` — the Node-style `code` (`ENOENT`, `EEXIST`, ...) off an unknown error,
  or `undefined`. Lets the adapters branch on filesystem-error semantics without depending on
  a specific fs implementation (both `node:fs` and the Tauri-fs binding surface a `code`).

## Relations

- Used by storage/nativeFsStorageAdapter.md, workspace.md, git/nativeGitAdapter.md, node.md.
