//! The Tauri host for the SlideBlaster desktop shell.
//!
//! Today it only opens a webview onto the shared editor app (parity with the web
//! shell). The native port adapters — filesystem storage, native git, keychain auth,
//! print/export — will be added here as `#[tauri::command]`s (or plugins) that the
//! TypeScript `@slideblaster/adapters-native` package invokes.

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
