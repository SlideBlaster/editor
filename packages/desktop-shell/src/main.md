# desktop-shell entry (main.ts)

The Tauri shell's entry point — the mirror of the web shell's `main.ts`, differing only in
its adapters and its landing screen. It mounts the shared editor app
([@slideblaster/app](../../app/src/index.md)) into the webview's `#app`.

## What it wires

- **Open a real folder as a working copy.** Instead of browser projects, a native folder
  picker (`@tauri-apps/plugin-dialog` `open({ directory: true })`) chooses a directory;
  `createNativeWorkspace({ dir, fs: tauriFs, watch: tauriWatch })`
  ([workspace.md](../../adapters-native/src/workspace.md)) mounts it as Storage + Git over
  the Tauri-fs binding ([tauriFs.md](./tauriFs.md)), and `createApp` gets `{ storage, git,
auth }`. **Local-first:** opening a folder needs no account and no GitHub; the working
  copy gets a local git repo (branch `main`, no remote). A remote can be added later from
  the source-control panel.
- **Recents + last-open**, kept as plain paths in `localStorage`; reload-based routing keeps
  teardown trivial (every hop is a fresh page), matching the web shell. `onExitToProjects`
  clears the open dir and returns to the picker.
- **Auth:** the offline `DevAuthAdapter` (adapters-browser) — instant local identity, no
  backend.
- **Self-update on startup** via [update.md](./update.md) — a wholly separate channel from
  the user's decks.

## Relations

- Shares all editor UI/behaviour with `web-shell` (ADR 0013 parity). Adapters:
  [tauriFs.md](./tauriFs.md), ../../adapters-native/src/workspace.md. Rust host in
  `../src-tauri` ([README](../README.md)); Vite frontend is this `src/` + `index.html`.
