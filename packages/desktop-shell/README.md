# @slideblaster/desktop-shell

The desktop application: a Tauri 2 app that mounts the shared editor app
(`@slideblaster/app`) in a native webview and, as they land, wires the **native**
port adapters (`@slideblaster/adapters-native`: filesystem storage, native git,
keychain auth, print/export). Replaces the prototype's CLI launcher. A launch
prerequisite alongside `web-shell` (ADR 0013).

The editor UI is shared with `web-shell` (implement once) — this package owns only
the Tauri host (`src-tauri/`, Rust) and the thin frontend mount (`src/main.ts`,
`index.html`, `vite.config.ts`). Right now it opens a window showing exactly what the
web shell shows (the bundled in-memory sample): the cross-shell parity ADR 0013 makes
a launch gate.

## Layout

```
src/main.ts          mounts @slideblaster/app into the webview (thin, mirrors web-shell)
index.html           #app root + module script
vite.config.ts       Tauri-conventioned Vite server (port 1420)
src-tauri/            the Rust host
  Cargo.toml         crate: tauri 2 + tauri-build
  tauri.conf.json    window, dev URL, bundle config
  build.rs           tauri-build codegen
  src/main.rs        binary entry -> lib::run()
  src/lib.rs         tauri::Builder; native #[tauri::command]s go here (M5)
  capabilities/      permission grants for the main window
  icons/             placeholder PNGs (see icons/README.md)
```

## Prerequisites

Tauri needs a native toolchain the JS install does not provide:

- **Rust** (`rustup`, stable) — https://rustup.rs
- **System webview + build deps** — on Linux: `webkit2gtk-4.1`, `librsvg`,
  `libayatana-appindicator`, `build-essential` (see the Tauri prerequisites guide for
  your OS).

## Run

```
corepack pnpm install                                        # once, from the editor root
corepack pnpm --filter @slideblaster/desktop-shell tauri:dev    # dev window (starts Vite + Rust)
corepack pnpm --filter @slideblaster/desktop-shell tauri:build  # package the app
```

`tauri:dev` runs the Vite frontend (`beforeDevCommand`) and the Rust host together.
Before a release build, generate real icons (see `src-tauri/icons/README.md`).

See `../../PROJECT.md`.
