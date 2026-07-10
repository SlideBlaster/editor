# workspace zip codec (workspaceZip.ts)

A port-generic export/import of the whole working copy as a single `.zip` — the
no-GitHub way to move a project between machines and between the web and desktop
shells. It operates purely over the [Storage port](../../editor/src/ports/storage.md),
so any shell reuses it unchanged; the browser download/upload glue is the only
platform-specific part (see [createApp.md](./createApp.md) and [export.md](./export.md)).

## Contract

- `exportWorkspaceZip(storage)` — walk every file under the root recursively (the same
  `.git`-excluded traversal as `findDocs`/`listFilesUnder`, [workspace.md](./workspace.md)),
  read each file's bytes through the port, and pack them into a zip whose entry names are
  the full working-copy-relative POSIX paths. Paths are sorted, so the archive is
  deterministic for a given tree. Returns the zip bytes; the caller owns the download.
- `importWorkspaceZip(storage, bytes, opts?)` — unzip and write each entry back through
  `storage.write`. Directory entries (trailing `/`) are ignored. `opts.onWrite(path)` and
  `opts.onSkip(name, reason)` report progress and refusals for UI feedback. Throws if the
  bytes are not a valid zip (the caller surfaces the error).
- `sanitizeZipEntryPath(name)` — the security boundary, exported so the guarantee is
  testable. Returns a safe relative path or `null` to refuse.

## Security (zip-slip)

Every entry name is sanitized before any write:

- Absolute paths are refused — a POSIX root (`/etc/x`) or a Windows drive (`C:\x`).
- Any `..` segment is refused (the classic zip-slip escape).
- `.` and empty segments are collapsed; a backslash is treated as a separator so Windows
  archives normalize instead of smuggling a path.
- A non-null result never starts with `/` and never contains `..`, so `storage.write`
  can only ever land **inside** the root.
- `.git` internals (a `.git` segment at any level) are skipped on both export and import,
  so the repository is never packed or clobbered. `.gitignore` / `.github` are ordinary
  files and travel normally.

## Overwrite / merge behavior

Import **merges into the root, last-writer-wins on a matching path** (exactly
`storage.write`'s contract). It does not namespace under an `imported-<timestamp>/`
prefix, and does not delete working-copy files that are absent from the zip (a merge,
not a mirror).

Why root-merge, not a prefix: cross-file references in a working copy are **root-relative**
— a deck names its bibliography by a bare `bibliography:` path resolved from the root
([citeCompiler.md](./citeCompiler.md)), and themes live at `themes/<id>/theme.json`
([browser-working-copy], [theme-layers]). Nesting an imported deck under a prefix would
break those references, since the referenced files would no longer sit at the expected
root path. Root-merge preserves every reference and matches the mental model of restoring
a working copy. It is kept safe by three things: unrelated files are preserved (only
matching paths are replaced), each web project is already its own working-copy directory,
and git history keeps committed versions of anything overwritten. Callers should confirm
before importing (the app chrome does) since a matching path is replaced without a prompt
per file.

## Assumptions

- Working copies are small (a handful of decks, figures, theme files, assets, `refs.bib`),
  so a synchronous `zipSync`/`unzipSync` in memory is fine — no streaming/worker needed.
- Byte-lossless: DEFLATE round-trips bytes exactly, so export -> import reproduces every
  file's path and content identically.
