# PROJECT — SlideBlaster monorepo

The canonical module map. Orient here first; keep it in sync whenever modules
change (per `AGENTS.md`).

## What this is

A presentations editor that is LaTeX/TikZ-native, where `*.slideBlaster.md` files in
the user's own GitHub repo are the source of truth. One platform-agnostic editor
core reaches every external capability through a **port**; per-platform **adapters**
implement the ports; one shared **app** holds the whole editor UI; two thin **shells**
(web, desktop) mount it and wire the adapters; two small **services** are our only
infra. Full design in the sibling `design/` repo.

## Layout

```
editor/                         <- this monorepo (pnpm workspace)
  packages/
    editor/            @slideblaster/editor            core: defines the six ports (engine at M1)
    app/               @slideblaster/app               shared editor UI: controller + canvas/code/deck/props (createApp)
    adapters-browser/  @slideblaster/adapters-browser  isomorphic-git + CORS proxy, IndexedDB/FSA, y-webrtc, export
    adapters-native/   @slideblaster/adapters-native   native FS + git + keychain + print (Tauri)
    adapters-shared/   @slideblaster/adapters-shared   WASM latexml compile (scaffold; engine unbuilt), collab client
    web-shell/         @slideblaster/web-shell         thin Vite app: mounts app + browser adapters
    desktop-shell/     @slideblaster/desktop-shell     thin Tauri app: mounts app + native adapters
  services/
    auth/       Phoenix: GitHub App, token minting, identity, capabilities      (built; KMS-swappable key)
    collab/     Phoenix: P2P signaling + premium server sessions + WAL           (not a pnpm package)
    git-proxy/  first-party CORS proxy for browser git (token transits it)       (Cloudflare Worker)
```

Sibling repos at the project root: `design/` (ADRs, format, architecture, roadmap),
`knowledge/` (concept graph), `infra/`.

## The six ports (`packages/editor/src/ports`)

| Port    | Responsibility                                                | ADR        |
| ------- | ------------------------------------------------------------- | ---------- |
| Storage | working copy: list/read/write/watch files + assets            | 0008       |
| Git     | status/stage/commit/log/diff/branch/merge/clone/pull/push     | 0001, 0008 |
| Auth    | identity + short-lived repo-scoped tokens; capability flags   | 0010       |
| Collab  | session lifecycle + CRDT transport + awareness (off for solo) | 0011, 0012 |
| Compile | table -> HTML (WASM latexml, wired into web-shell)            | 0009       |
| Export  | PDF + standalone presenter HTML from rendered slides          | 0009       |

Bundled into the core with no port: the TikZ renderer, KaTeX, fonts (ADR 0003) —
the render path is fully client-side.

## Conventions

- **Code Database:** every `foo.ts` has a companion `foo.md` describing its abstract
  contract (see `AGENTS.md`). Keep them in sync.
- **Tooling:** pnpm workspaces, TypeScript strict + ESM, vitest, prettier, GitHub
  Actions CI (`format:check` -> `typecheck` -> `test`).
- **Knowledge base:** search `../knowledge/` before researching a concept; write
  back what you learn (project-root `AGENTS.md`).

## Status

- **M0:** scaffold + the six port interfaces. Done in `packages/editor`.
- **M1 (engine):** built in `packages/editor` — model, markdown round-trip, TikZ
  subset, measure->resolve->render layout, edit ops, connectors, invariants.
- **M2 (editor app):** built in `packages/app` — canvas deck, code pane, deck
  navigator, properties, creation menu, undo/redo, snapping, zoom, export.
- **M3 (browser working copy):** landed. `packages/adapters-browser` has the
  Storage port (`FsStorageAdapter`) and Git port (`IsomorphicGitAdapter`, incl.
  `init`) over **one shared LightningFS/IndexedDB fs** (`createBrowserWorkspace`,
  bootstraps `git init` on first run) plus `DevAuthAdapter` (AuthPort stand-in
  until M4). The app takes `ports` and adds autosave persistence, the file tree,
  and the source-control panel (status / stage-all commit / log; author from the
  Auth port); web-shell wires it all. Offline solo works end-to-end.
- **Track-0 spikes:** browser git + CORS proxy landed (`services/git-proxy`);
  async measurement layout landed (`app/domMeasurer`); WASM latexml **built and
  wired** — the engine (`adapters-shared/.../engine/dist`, Git LFS) drives the
  Compile port through a Web Worker, so a slide `tabular` renders as compiled HTML
  in web-shell (the default sample deck now includes a table). The app bridges the
  async port to the synchronous render/measure seam with a debounced compile cache
  (`app/tableCompiler`). **Remaining: Yjs<->AST round-trip (ADR 0011) — not
  started.**
- **M4 Phase A (all-local) — landed.** The full signed-in client path runs with
  no GitHub, KMS, or Phoenix: `BrowserAuthAdapter` (real `AuthPort` — OAuth-redirect
  sign-in, `/me` session probe, `/mint` repo-scoped tokens cached in memory,
  CSRF); `services/auth-stub`, a dev double speaking the exact Auth-service HTTP
  contract (fakes OAuth + minting); connect-a-repo push/pull in the source-control
  panel (`git.push/pull` now target `RemoteRef.url` directly, so an `init`'d
  working copy needs no preconfigured `origin`); web-shell selects the adapter from
  `VITE_SB_AUTH_URL` and proxies auth routes to the stub same-origin. Proven by a
  real-HTTP adapter↔stub integration test and a live Vite-proxy run.
- **M4 Phase B (deployment) — in progress.** Vertical slice first: real GitHub
  push/pull with KMS deferred behind a swappable seam. **Built:** the real Phoenix
  Auth service (`services/auth`) — full HTTP contract (drop-in for the stub), real
  GitHub OAuth, and installation-token minting authorized against the user's own
  installations; the App private key is held locally behind a KMS-swappable
  `MintingKey` (RS256 App-JWT signing unit-verified); git-proxy `wrangler.toml`
  (bundles clean). **User gates cleared:** GitHub App registered, Elixir toolchain.
  **Remaining:** drop the client secret + `.pem` into `services/auth/.env`, deploy
  git-proxy to Cloudflare (`wrangler login`), and drive the live sign-in →
  push/pull. **Then the KMS/hardening pass:** `MintingKey.Kms`, split the minting
  service, revocation webhooks, durable sessions. Also open before M6: Yjs<->AST
  round-trip (ADR 0011).

Milestones M0-M8: `../design/roadmap.md`.
