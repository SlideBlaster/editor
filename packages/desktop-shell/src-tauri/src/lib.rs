//! The Tauri host for the SlideBlaster desktop shell.
//!
//! A thin native host: it registers the plugins the TypeScript shell drives — dialog
//! (folder picker), fs (the working-copy filesystem, with `watch`), process (relaunch
//! after an update), and the desktop-only updater (self-update from GitHub Releases).
//! The working-copy Storage + Git logic lives in TypeScript (`@slideblaster/adapters-native`)
//! running in the webview over the fs plugin, so there are no custom `#[tauri::command]`s yet.

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    #[allow(unused_mut)]
    let mut builder = tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_fs::init())
        .plugin(tauri_plugin_process::init());

    // The updater plugin exists only on desktop targets.
    #[cfg(desktop)]
    {
        builder = builder.plugin(tauri_plugin_updater::Builder::new().build());
    }

    builder
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
