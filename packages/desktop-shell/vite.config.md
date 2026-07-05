# desktop-shell vite config

Vite dev server + static build for the Tauri desktop application (ADR 0013, ADR
0008). The frontend is the shared editor app (`@slideblaster/app`) plus the native
adapters, all workspace deps shipped as TypeScript **source** — Vite type-strips and
bundles them directly, nothing to compile ahead of time.

Follows Tauri's frontend conventions:

- **Port 1420, `strictPort`** — the URL Tauri's `devUrl` points at; fail rather than
  silently pick another port.
- **`clearScreen: false`** — keep the Rust/`cargo` logs from `tauri dev` visible.
- **`watch.ignored` `src-tauri/**`** — the Rust host has its own rebuild loop.
- **`envPrefix` includes `TAURI_`** — Tauri injects platform env vars for the frontend.
- **`es2022` target** — matches `tsconfig.base.json`.

`tauri dev` runs this via `beforeDevCommand`; `tauri build` runs the static build via
`beforeBuildCommand`, then packages `../dist` (see `src-tauri/tauri.conf.json`).
