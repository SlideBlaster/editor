# NativeFsStorageAdapter

The native Storage port (ADR 0008): the editor's working copy over a real directory,
the desktop peer of the browser `FsStorageAdapter`. It is rooted at a real directory —
**the same directory the native git adapter uses**, so the Git port sees every storage
write.

## Contract

- Implements `StoragePort` from `@slideblaster/editor`.
- **Options** (`NativeFsStorageAdapterOptions`): `dir` (working-copy root, identical to
  the git adapter's `dir`); `fs`, an injected isomorphic-git `PromiseFsClient`; and an
  optional `watch` (`NativeWatch`).
- **Injected filesystem (runtime-agnostic).** The adapter never imports `node:*`. It
  drives `fs.promises` only, so the identical, tested code runs under Node (the `node:fs`
  binding in [node.md](../node.md)) and inside the Tauri webview (a plugin-fs binding —
  `desktop-shell/src/tauriFs.md`) which has no Node. This is what makes the class bundle
  into the webview.
- Paths are working-copy-relative and POSIX; leading `./`/`/` are tolerated, `..` is
  rejected ([paths.md](../paths.md)). `abs` joins with `/` (accepted by Node and Tauri on
  every target). `list` is non-recursive, directories sorted before files. `write` creates
  intermediate directories level by level (portable; no reliance on recursive `mkdir`),
  last-writer-wins. `remove` deletes a file, or a directory subtree depth-first. `read`
  returns a standalone `Uint8Array`; `readText` decodes UTF-8.
- `watch` **delegates to the injected `NativeWatch`**; with none it is a no-op (best-effort
  per the port contract). The Node binding observes EXTERNAL changes (git, other tools) as
  well as the adapter's own writes, debounced and resolved to a single
  create/update/delete FileEvent with a POSIX-relative path (see [node.md](../node.md)).

## Validation

Unit-tested against a real temp dir under `node:os` tmpdir, injecting the `node:fs`
binding and its watcher (`nativeFsStorageAdapter.test.ts`), including an external write
observed through `watch`. The Tauri-fs binding is typechecked only (no headless runtime).
