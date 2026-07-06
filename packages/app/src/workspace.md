# workspace (app-side port glue)

The seam between the controller and the Storage port: documents live in the
working copy, the controller edits one of them at a time.

## Contract

- `AppPorts` — the bundle a shell passes to `createApp` (`storage`, `git`,
  `auth`). Optional at the app level: without ports the app runs the in-memory
  sample exactly as before M3.
- `findDocs(storage)` — every `*.slideBlaster.md` in the working copy,
  recursive, `.git` excluded, sorted.
- `bootDocument(storage, sampleSource)` — startup document selection: seeds the
  bundled sample into an empty working copy, then prefers the last-opened doc
  (localStorage, best-effort) over the first found.
- `rememberDoc(path)` — record the last-opened doc.
- `createAutosave(storage, { onWrite?, delayMs? })` — a debounced write-through:
  `schedule(path, source)` supersedes prior pending writes; `flush()` forces the
  pending write (called on doc switch, before commit, and on unload);
  `discard()` drops a pending write whose target was deleted or renamed away
  (flushing it would resurrect the file). `onWrite` fires after each completed
  write so dependent views (the git panel) can refresh. Autosave persists the
  current source only; durability and history remain the Git port's job.

## Invariants

- Only this module decides _which_ file the controller edits; the controller
  owns _what_ the content is.
- A schedule/flush pair never writes stale content: the latest scheduled source
  wins.
