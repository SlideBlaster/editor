# projects (registry)

The list of projects the landing page shows. A **project is one git working copy
(= one repo)** holding any files/dirs; its `*.slideBlaster.md` files are its
presentations (product.md, ui.md). This module is metadata only — id, name,
timestamps — persisted in browser storage. The working copy itself lives at
`/projects/<id>` in the browser FS and is created lazily by the shell
(`createBrowserWorkspace({ dir })`) when the project is opened; the registry never
touches storage or git.

## Contract

- `createProjectRegistry(store?)` -> `{ list, get, create, touch, remove }`. The
  `store` (a `StorageLike`) defaults to `localStorage`, or an in-memory map when
  it is unavailable (tests/SSR) — so the registry is unit-testable in node.
- `Project`: `{ id, name, createdAt, lastOpenedAt }`. `id` is a `crypto.randomUUID`
  that doubles as the working-copy directory name.
- `list()` returns projects most-recently-opened first. `create(name)` mints a
  project (blank name -> "Untitled project") and persists it. `touch(id)` marks it
  opened now and moves it to the front (stable ordering even for same-millisecond
  opens). `remove(id)` forgets the metadata; **the working-copy dir is left in
  place** (no fs access here).
- All reads tolerate malformed/absent stored data by returning `[]`; all writes
  are best-effort (storage may be unavailable).
