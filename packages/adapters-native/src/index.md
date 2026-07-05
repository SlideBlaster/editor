# adapters-native entry (index.ts)

The public surface of `@slideblaster/adapters-native`: the native (Tauri)
implementations of the editor ports, consumed by `desktop-shell` and handed to
`createApp`.

Empty until milestone M5. Planned adapters (ADR 0008): native filesystem (Storage),
native git (Git), OS keychain for the Auth session secret, and Tauri webview
print/export (Export). Collab and Compile reuse `@slideblaster/adapters-shared`.
Each adapter is a thin TypeScript wrapper over `@tauri-apps/api` `invoke` calls into
`#[tauri::command]`s (or Tauri plugins) in `../desktop-shell/src-tauri`.
