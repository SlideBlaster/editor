# @slideblaster/adapters-browser

Browser implementations of the editor ports, wired by `web-shell`.

| Port    | Planned implementation                                                       |
| ------- | ---------------------------------------------------------------------------- |
| Storage | IndexedDB or File System Access API                                          |
| Git     | isomorphic-git over the browser FS, pushing through a first-party CORS proxy |
| Auth    | client to the Auth service; session in an http-only cookie                   |
| Collab  | y-webrtc (P2P) / y-websocket to Phoenix (premium)                            |
| Compile | WASM latexml (via `adapters-shared`); JS table-subset interim                |
| Export  | browser print-to-PDF; standalone HTML                                        |

## Spike focus (Track 0)

**Browser git + first-party CORS proxy.** Clone/commit/push a real GitHub repo from
the browser via isomorphic-git. GitHub's git HTTP endpoints are not CORS-enabled, so
isomorphic-git needs an `http` transport pointed at a **first-party** proxy. A
short-lived, repo-scoped `contents` token (Auth port, ADR 0010) transits that proxy,
so it must be non-logging and locked to github.com git endpoints (`auth.md`).

Empty until the spike approach is agreed; see `../../PROJECT.md`.
