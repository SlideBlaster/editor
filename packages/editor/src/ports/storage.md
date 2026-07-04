# Storage port

The editor's working copy: the flat tree of files and assets a presentation is made
of — `*.slideBlaster.md` documents, `.bib` files, images, `\cat` includes, and theme
files.

## Contract

- Paths are working-copy-relative with POSIX separators; the root is `''` or `'.'`.
- `list` is non-recursive (one directory level).
- `read` returns raw bytes; `readText` decodes UTF-8. `write` accepts bytes or a
  string (encoded UTF-8). `write` creates intermediate directories as needed and is
  last-writer-wins; it does not merge.
- `watch` reports create/update/delete under a file or subtree and returns an
  `Unsubscribe`. Delivery is best-effort and may coalesce rapid events.
- This is the working copy only — durability and history belong to the **Git** port.
  Storage never talks to a remote.

## Adapters

Browser: IndexedDB or the File System Access API. Native: the OS filesystem
(Tauri). Managed: a hosted API. See `design/architecture/README.md`.
