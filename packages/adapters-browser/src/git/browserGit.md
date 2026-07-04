# browserGit

Browser factory that constructs an `IsomorphicGitAdapter` with the browser-specific
dependencies: an IndexedDB-backed LightningFS working copy and isomorphic-git's web
http client, pointed at the first-party CORS proxy.

- `createBrowserGitAdapter({ corsProxy, dir?, fsName? })` -> a ready `GitPort`.
- `fsName` names the IndexedDB database backing the working copy (one per project).
- Kept separate from the adapter core so Node tests can construct the adapter with
  `node:fs` and never load LightningFS/IndexedDB.
