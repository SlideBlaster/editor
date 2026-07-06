# gitPanel

The source-control sidebar: local history over the working copy plus GitHub sync.
Status, stage-all commit, the recent log, and connect-a-repo push/pull — all
through the Git port; identity and repo tokens through the Auth port.

## Contract

- `createGitPanel(host, { git, auth, beforeCommit, getRemote, setRemote,
afterPull, onError, onInfo }) -> { refresh }`. `refresh()` reloads status + log
  (depth 20) and repaints; the controller calls it after boot, after edits
  settle, and after file-tree mutations.
- **Commit** stages every changed path and commits with the author derived from
  `auth.currentIdentity()` (`login` / `login@users.noreply.github.com`). Not
  signed in -> commit disabled, a sign-in button is offered instead; the panel
  never invents an identity. An empty message falls back to "update slides".
- `beforeCommit` runs first (the controller flushes autosave) and staging uses a
  status taken _after_ the flush, so a commit always includes the latest source.
- **Sync** (M4, shown only when signed in): `getRemote`/`setRemote` persist the
  connected `owner/name`; a connect form appears until one is set. **Push** flushes
  pending edits, mints a token via `auth.getRepoToken({owner,name})`, and
  `git.push`es to `https://github.com/owner/name.git`. **Pull** mints, `git.pull`s,
  then calls `afterPull` so the controller reopens the (rewritten) working copy;
  conflicts are surfaced, not merged here. Push/Pull labels show ahead/behind when
  the Git port reports them.
- `onError`/`onInfo` report failures and progress/success through the controller's
  status bar; the panel stays usable.

## Assumptions

- Single-user local repo: no concurrent committer, stage-all is safe.
