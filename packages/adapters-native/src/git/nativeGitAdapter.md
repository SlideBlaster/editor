# NativeGitAdapter

The native Git port (ADR 0008), implemented with isomorphic-git over an injected
filesystem — the desktop peer of the browser `IsomorphicGitAdapter`. Using
isomorphic-git (rather than a shelled-out git binary) maximizes parity with the browser
adapter: the same logic, the same status/merge semantics, no external dependency.
isomorphic-git is itself browser-safe (the web shell already runs it), and this file has
**no `node:*` import**, so it bundles into the Tauri webview.

## Contract

- Implements `GitPort` from `@slideblaster/editor`.
- **Options** (`NativeGitAdapterOptions`): `dir` (working-copy root); `fs`, an injected
  isomorphic-git `PromiseFsClient` (**required** — see the `node:fs` one in
  [node.md](../node.md), the Tauri one in `desktop-shell/src/tauriFs.md`); `http`, an
  optional `HttpClient` needed only for remote ops; `mergeAuthor`, the committer for merge
  commits created by `pull`/`merge`. Remote ops call `requireHttp()`, which throws a clear
  error if no `http` was injected.
- **No CORS proxy.** Unlike the browser adapter, native git reaches remotes directly
  (Node has no CORS), so there is no `corsProxy` seam; `push`/`pull`/`clone` target
  `RemoteRef.url` directly and work on an `init`'d working copy with no preconfigured
  `origin`.
- **Auth:** remote operations take a `RemoteRef` whose `ScopedToken` is sent as
  GitHub HTTP basic auth (`x-access-token` : token). The adapter never stores the
  token; the caller passes one per call.
- **Scope:** `init/clone/status/stage/commit/log/currentBranch/checkout/createBranch`
  are implemented; `merge`/`pull` handle the fast-forward and conflict-reporting
  cases; `push` reports rejection as an error. `status` ahead/behind is stubbed to 0
  (deferred until a remote exists, as in the browser adapter). `stage` routes
  deletions to `git.remove`. `init` creates a fresh local-only repository (default
  branch `main`) — the offline-first path, needing no remote and no credentials.
  `log` on an unborn branch returns `[]` rather than throwing.

## Validation

Local history (`init` -> write -> stage -> commit -> log/status), branch/checkout,
and a clean merge are covered by always-on offline tests against a real temp dir
(`nativeGitAdapter.test.ts`). `push`/`pull` require a live remote and are
integration-only; they are exercised by the same code path as the browser adapter's
env-gated round-trip but are not run offline.
