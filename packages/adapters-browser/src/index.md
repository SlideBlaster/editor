# @slideblaster/adapters-browser (public surface)

Browser implementations of the editor ports. Exposes:

- **Workspace (the usual entry):** `createBrowserWorkspace` — Storage + Git over
  one shared LightningFS/IndexedDB working copy, bootstrapped (`git init`) on
  first run. Shells wire this pair into the app.
- **Git:** `IsomorphicGitAdapter` (injectable core), `createBrowserGitAdapter`
  (git-only browser wiring, kept for spikes).
- **Storage:** `FsStorageAdapter` (injectable core over a promises-style fs).
- **Auth:** `DevAuthAdapter` — the AuthPort stand-in until the Auth service (M4).

Collab, Compile, and Export adapters attach here at their milestones.
