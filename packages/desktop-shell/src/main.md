# desktop-shell entry (main.ts)

The Tauri shell's entry point — deliberately thin, the mirror of the web shell's
`main.ts`. It mounts the shared editor app
([@slideblaster/app](../../app/src/index.md)) into the webview's `#app` element and
tags the app bar with `desktop · M5`.

All editor UI and behaviour is shared with `web-shell` (implement once); this file's
future job is to build the **native** port adapters — native filesystem (Storage),
native git (Git), OS keychain (Auth), Tauri print/export — over `@tauri-apps/api`
and [@slideblaster/adapters-native](../../adapters-native/README.md), and hand them
to `createApp`. Today it passes no adapters, so the desktop app renders exactly what
the web app does: the bundled in-memory sample. This is the cross-shell parity check
that ADR 0013 makes a launch gate.

The Rust host lives in `../src-tauri` ([README](../README.md)); the Vite frontend it
loads is this `src/` + `index.html`.
