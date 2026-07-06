# Git port

Durability, history, branching, and sync over the same working copy the Storage
port exposes. Git is the persistence and merge mechanism for the whole product
(ADR 0001); the CRDT is not.

## Contract

- Operates on the working copy in place. `stage` / `commit` build local history;
  `pull` / `push` move it to and from the user's GitHub repo.
- A working copy comes into being either by `clone` (from a remote) or by `init`
  (a fresh local-only repository, default branch `main`). `init` needs no
  credentials; a remote can be attached later when the user connects GitHub.
- Remote operations take a `RemoteRef` carrying a short-lived `ScopedToken` from the
  Auth port. The port never stores credentials; the caller passes one per call.
- `pull` and `merge` surface `conflicts` (a path list) rather than throwing on
  divergence; the locality-preserving serializer auto-merges most cases and the
  merge UI handles the rest.
- `commit` returns the new `Oid`. `status` reports branch, ahead/behind, and
  per-file index/worktree state.
- In premium collab the server is single-writer-per-repo; in P2P the owner's client
  is the sole committer (ADR 0012). Either way commits go through this port.

## Adapters

Browser: isomorphic-git over the browser FS, pushing through a first-party CORS
proxy (a repo-scoped token transits it). Native: native git (Tauri). Managed:
server-side git. See `design/architecture/README.md` and `auth.md`.
