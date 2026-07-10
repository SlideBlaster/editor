# @slideblaster/desktop-shell

The desktop application: a Tauri 2 app that mounts the shared editor app
(`@slideblaster/app`) in a native webview and wires the **native** port adapters
(`@slideblaster/adapters-native`). It opens a **real folder on disk** as a local,
git-backed working copy — no account and no GitHub required — and self-updates the app
binary from GitHub Releases. A launch prerequisite alongside `web-shell` (ADR 0013).

The editor UI is shared with `web-shell` (implement once) — this package owns only the
Tauri host (`src-tauri/`, Rust) and the thin frontend (`src/`, `index.html`,
`vite.config.ts`).

## What it does

- **Open Folder →** native picker (`plugin-dialog`) → `createNativeWorkspace({ dir, fs,
watch })` mounts Storage + Git over the folder via a Tauri-fs binding (`src/tauriFs.ts`),
  and `createApp` gets the ports. First open runs a local `git init` (branch `main`); no
  remote, no credentials. Recents + last-opened are kept in `localStorage`.
- **Self-update on startup** (`src/update.ts`): checks our GitHub Releases and, with the
  user's consent, downloads/installs/relaunches. This updates the **app binary only** — a
  wholly separate channel from your decks, which are just local files/git repos.

## Layout

```
src/main.ts          folder picker + recents + createNativeWorkspace + createApp + self-update
src/tauriFs.ts       PromiseFsClient + NativeWatch over @tauri-apps/plugin-fs (webview fs binding)
src/update.ts        checkForUpdatesOnStartup() via plugin-updater + plugin-process
index.html           #app root + module script
vite.config.ts       Tauri-conventioned Vite server (port 1420)
src-tauri/            the Rust host
  Cargo.toml         tauri 2 + dialog/fs/process plugins; updater (desktop-only target)
  tauri.conf.json    window, dev URL, bundle + updater config (createUpdaterArtifacts, endpoints, pubkey)
  src/lib.rs         tauri::Builder registering the plugins
  capabilities/      permission grants for the main window (dialog, fs, process, updater)
  icons/             placeholder PNGs (see icons/README.md)
```

## Prerequisites

Tauri needs a native toolchain the JS install does not provide:

- **Rust** (`rustup`, stable) — https://rustup.rs
- **System webview + build deps** — Linux: `webkit2gtk-4.1`, `librsvg`,
  `libayatana-appindicator`, `build-essential` (see Tauri's prerequisites for your OS).

## Run

```
corepack pnpm install                                            # once, from the editor root
corepack pnpm --filter @slideblaster/desktop-shell tauri:dev     # dev window (Vite + Rust)
corepack pnpm --filter @slideblaster/desktop-shell tauri:build   # package the app
```

Before a release build, generate real icons (see `src-tauri/icons/README.md`).

## Releasing + self-update setup

Self-update requires signed bundles (Tauri v2). Before the first release:

1. **Generate a signing key:** `pnpm --filter @slideblaster/desktop-shell tauri signer generate`
   (keep the private key secret; never commit it).
2. **tauri.conf.json →** set `plugins.updater.pubkey` to the generated PUBLIC key and
   replace `OWNER/REPO` in `plugins.updater.endpoints`.
3. **Repo secrets:** `TAURI_SIGNING_PRIVATE_KEY`, `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`.
4. **Enable CI:** set repo variable `RELEASE_DESKTOP=true`, then push a `desktop-v*` tag —
   `.github/workflows/release.yml` (tauri-action) builds/signs the macOS, Windows, and Linux
   bundles, uploads them, and generates `latest.json` (the manifest the updater reads).

Updatable targets: Linux AppImage, macOS `.app`, Windows NSIS/MSI.

## Verification status

The TypeScript (shell wiring, the Tauri-fs binding, the updater flow) is covered by
`pnpm --filter @slideblaster/desktop-shell typecheck` and the shared `make check`. The Rust
build, the `tauri build` bundles, and the runtime behaviour of the Tauri-fs binding require
a Tauri toolchain (webview + Rust) and are **not** exercised by `make check`. See also the
knowledge notes: native-working-copy, workspace-zip-portability, desktop-self-update-github.

## Security notes

- The `fs` capability is currently scoped to `$HOME/**` so any picked folder works. Prefer
  narrowing it to the opened directory at runtime before shipping (see
  `src-tauri/capabilities/default.json`).
- Signing keys live only in CI secrets and a developer's keychain — never in the repo.

See `../../PROJECT.md`.
