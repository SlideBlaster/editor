# web-shell entry (main.ts)

The browser shell's entry point — deliberately thin. It is a tiny router over the
shared editor app ([@slideblaster/app](../../app/src/index.md)), mounted into the
page's `#app` element.

**Projects routing.** A project is one working copy (= repo). The shell lands on
the projects page (`renderHome` over a `createProjectRegistry`); opening a project
records it in `sessionStorage` and reloads into the editor, scoped to that
project's dir (`createBrowserWorkspace({ dir: '/projects/<id>' })`), with
`onExitToProjects` wired back to the landing. Routing is **reload-based** so each
hop is a clean page — `createApp` registers document-level listeners, and a full
reload avoids leaking them between the landing and the editor. A fresh tab (no
session pointer) always lands on the projects page.

Adapters wired: `createBrowserWorkspace` — the Storage and Git ports over one
shared LightningFS/IndexedDB working copy, bootstrapped on first run — and the
Auth port. `createAuth` picks the Auth adapter from `VITE_SB_AUTH_URL`: when set,
the real `createBrowserAuthAdapter({ baseUrl })` (GitHub sign-in + token minting),
where `/` means "this origin" — local dev through the Vite proxy to the auth-stub
(Phase A); a full URL is the deployed Auth service (Phase B). Unset, it falls back
to `DevAuthAdapter` (offline; instant local identity, optional `VITE_SB_DEV_PAT`
for manual remote git). Other optional env: `VITE_SB_GIT_PROXY` (first-party CORS
proxy URL, remote git only). If the working copy cannot open (IndexedDB
unavailable), the shell falls back to the in-memory sample.

Compile port (tables): `createCompilePort` wraps `WasmLatexmlCompiler` around a
`createWorkerLatexmlEngine` proxy to a Web Worker. The worker is the static
`public/latexml/worker.js` (classic, so it can `importScripts` the emscripten
glue); the shell hands it the three engine asset URLs — `perl-web.js` / `.wasm` /
`.data`, imported from adapters-shared via Vite `?url` so the 20 MB payload is
bundled once from its Git-LFS source. If Workers are unavailable the port is
omitted and tables render as "render pending" placeholders. This is why the shell
also depends on `@slideblaster/adapters-shared`.

All of the editor UI and behaviour lives in `@slideblaster/app` so it is shared
with `desktop-shell` (implement once). The KaTeX offline stylesheet and the
workspace styles come from the app package; this shell only owns
`vite.config.ts`, `index.html`, and this entry.
