# web-shell entry (main.ts)

The browser shell's entry point — deliberately thin. It builds the browser
adapters and mounts the shared editor app
([@slideblaster/app](../../app/src/index.md)) into the page's `#app` element,
tagged `web-shell · M3`.

Adapters wired (M3): `createBrowserWorkspace` — the Storage and Git ports over
one shared LightningFS/IndexedDB working copy, bootstrapped on first run — and
`DevAuthAdapter` for identity until the Auth service (M4). Optional env:
`VITE_SB_GIT_PROXY` (first-party CORS proxy URL, used by remote git only) and
`VITE_SB_DEV_PAT` (a PAT for manual remote testing; never shipped). If the
working copy cannot open (IndexedDB unavailable), the shell falls back to the
in-memory sample.

All of the editor UI and behaviour lives in `@slideblaster/app` so it is shared
with `desktop-shell` (implement once). The KaTeX offline stylesheet and the
workspace styles come from the app package; this shell only owns
`vite.config.ts`, `index.html`, and this entry.
