# workspace (app-side port glue)

The seam between the controller and the Storage port: documents live in the
working copy, the controller edits one of them at a time.

## Contract

- `AppPorts` — the bundle a shell passes to `createApp` (`storage`, `git`,
  `auth`, and optional `compile`). Optional at the app level: without ports the
  app runs the in-memory sample exactly as before M3. `compile` (the latexml
  Compile port) is itself optional even when ports are present — absent, tables
  render as "render pending" placeholders ([tableCompiler.md](./tableCompiler.md)).
- `isDocPath` / `isTikzPath` / `isEditablePath` — path classification. A **deck**
  is `*.slideBlaster.md`; a **figure** is `*.tikz` (a bare slide-picture body — no
  frontmatter or headings — authored on the canvas like a one-slide deck); an
  **editable** file is either. Everything else is an inert asset in the tree.
- `findDocs(storage)` — every `*.slideBlaster.md` in the working copy,
  recursive, `.git` excluded, sorted. Figures are intentionally excluded: they are
  openable from the tree but never auto-booted (see `bootDocument`).
- `bootDocument(storage, sampleSource, seedFiles?)` — startup document selection:
  seeds the bundled sample (and any `seedFiles` it references, e.g. its `refs.bib`
  bibliography) into an empty working copy, then prefers the last-opened doc
  (localStorage, best-effort) over the first found.
- `rememberDoc(path)` — record the last-opened doc.
- `RemoteConfig` (`{owner, name}`), `remoteUrl(remote)` (the GitHub HTTPS git
  URL), and `readRemote()` / `writeRemote(remote|null)` — persist the connected
  repo for M4 push/pull (localStorage, best-effort). The Git port token still
  comes per-call from the Auth port; only the repo identity is stored, never a
  credential.
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
