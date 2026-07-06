# createBrowserWorkspace

The browser shell's one-stop factory for the local working copy: the Storage and
Git adapters over a **single shared LightningFS (IndexedDB) filesystem** and a
single working-copy dir.

## Contract

- `createBrowserWorkspace({ fsName?, dir?, corsProxy? }) -> Promise<{ storage, git }>`.
- **Shared-fs invariant:** both adapters operate on the same fs instance and the
  same `dir`. A `storage.write` is immediately visible to `git.status()`/`stage`;
  a git `checkout`/`pull` changes the files storage reads. Building the two
  adapters over different fs instances or dirs silently breaks the product — use
  this factory, not the individual constructors, in shells.
- **Bootstrap:** on first run the working-copy dir is created and `git init`
  (branch `main`) is run, so the returned workspace always has local history
  available offline with no remote and no credentials (M3). An existing repo is
  left untouched.
- `corsProxy` is only consulted for remote git operations (clone/pull/push, M4);
  the offline path never uses it.

## Relations

- Wraps `FsStorageAdapter` (storage/fsStorageAdapter.md) and
  `IsomorphicGitAdapter` (git/isomorphicGitAdapter.md).
- `createBrowserGitAdapter` (git/browserGit.md) remains for git-only use (spikes);
  shells should prefer this factory.
