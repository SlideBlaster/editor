# gitPanel

The source-control sidebar: local history over the working copy (M3 gate —
"local working copy + history"). Status, stage-all commit, and the recent log,
all through the Git port; authorship through the Auth port.

## Contract

- `createGitPanel(host, { git, auth, beforeCommit, onError }) -> { refresh }`.
  `refresh()` reloads status + log (depth 20) and repaints; the controller calls
  it after boot, after edits settle, and after file-tree mutations.
- **Commit** stages every changed path and commits with the author derived from
  `auth.currentIdentity()` (`login` / `login@users.noreply.github.com`). Not
  signed in -> commit disabled, a sign-in button is offered instead; the panel
  never invents an identity. An empty message falls back to "update slides".
- `beforeCommit` runs first (the controller flushes autosave) and staging uses a
  status taken _after_ the flush, so a commit always includes the latest source.
- Failures are reported through `onError` (the controller's status bar); the
  panel stays usable.
- Remote sync (push/pull, ahead/behind) is deliberately absent until the Auth
  service mints real tokens (M4).

## Assumptions

- Single-user local repo: no concurrent committer, stage-all is safe.
