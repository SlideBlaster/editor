# FsStorageAdapter

The browser Storage port (ADR 0008): the editor's working copy over an injected
promises-style filesystem. In the browser that filesystem is LightningFS
(IndexedDB) — **the same instance the git adapter uses**, so the Git port sees
every storage write; under tests it is `node:fs.promises`.

## Contract

- Implements `StoragePort` from `@slideblaster/editor`.
- **Injected dependencies** (`FsStorageAdapterOptions`): `fs` (the `PromiseFs`
  subset of fs.promises that LightningFS and node:fs share) and `dir` (the
  working-copy root inside `fs`, identical to the git adapter's `dir`).
- Paths are working-copy-relative, POSIX; leading `./`/`/` are tolerated and
  `..` is rejected. `list` is non-recursive, directories sorted before files.
- `write` accepts bytes or a UTF-8 string, creates intermediate directories,
  last-writer-wins. `remove` deletes a file, or a directory subtree depth-first.
- `watch` is an in-process feed of this adapter's own `write`/`remove` calls
  (create/update/delete), filtered by path prefix. Best-effort by contract:
  changes made behind the adapter's back (e.g. git checkout) are not observed —
  callers refresh after git operations.

## Validation

Unit-tested against `node:fs.promises` in a temp dir (`fsStorageAdapter.test.ts`).
