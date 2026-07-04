# IsomorphicGitAdapter

The browser Git port (ADR 0008), implemented with isomorphic-git. Provides the
durability/history/sync half of the free tier: the client does its own git against
the user's GitHub repo (ADR 0001), so no server holds the working copy.

## Contract

- Implements `GitPort` from `@slideblaster/editor`.
- **Injected dependencies** (`IsomorphicGitAdapterDeps`): `fs` (an isomorphic-git
  `FsClient`), `http` (an isomorphic-git `HttpClient`), `corsProxy`, `dir`. Injection
  is what lets the same logic run in the browser (LightningFS + http/web) and under
  Node tests (node:fs + http/web) — see `browserGit.ts` for the browser wiring.
- **Auth:** remote operations take a `RemoteRef` whose `ScopedToken` is sent as
  GitHub HTTP basic auth (`x-access-token` : token). The adapter never stores the
  token; the caller passes one per call.
- **Proxy:** all remote traffic goes through `corsProxy` (the first-party
  `services/git-proxy`), because GitHub's git-smart-http is not CORS-enabled.
- **Spike scope:** `clone/status/stage/commit/log/currentBranch/checkout/
createBranch/push` are implemented; `pull`/`merge` handle the fast-forward and
  conflict-reporting cases; `status` ahead/behind is stubbed to 0 (deferred past the
  spike). `stage` routes deletions to `git.remove`.

## Validation

Proven by an env-gated integration test that stands up an in-process proxy and
round-trips a real scratch repo (`isomorphicGitAdapter.test.ts`). The in-browser
CORS + IndexedDB path is validated separately (see the package README).
