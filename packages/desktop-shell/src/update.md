# desktop self-update (update.ts)

`checkForUpdatesOnStartup()` — checks our GitHub Releases `latest.json` on launch and, only
with the user's consent, downloads, installs, and relaunches the app.

## Contract

- Uses `@tauri-apps/plugin-updater` `check()` (endpoint + minisign pubkey come from
  tauri.conf.json), prompts via `@tauri-apps/plugin-dialog` `ask`, then
  `update.downloadAndInstall()` + `@tauri-apps/plugin-process` `relaunch()`.
- **Two separate channels (by design):** this updates the APP BINARY only. A user's decks
  are local files / git repos and are NOT tied to GitHub or this release.
- Fire-and-forget and fully swallowed on error, so an offline/misconfigured/absent update
  channel never blocks the editor. No update available -> `check()` returns null -> no-op.

## Validation

Typechecked against the plugin APIs only. Requires a signed release + a running Tauri build
to exercise; not verifiable headlessly. See [../README.md](../README.md) and the
desktop-self-update-github knowledge note.
