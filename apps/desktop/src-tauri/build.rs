fn main() {
    // Declare the shell's own commands as permissions: Tauri 2 only lets remote origins
    // (the `sb serve` page on 127.0.0.1) call app commands that a capability grants.
    tauri_build::try_build(tauri_build::Attributes::new().app_manifest(
        tauri_build::AppManifest::new().commands(&["open_folder_dialog", "shell_ready", "open_presenter", "debug_log",
            "list_presentations", "open_presentation", "add_presentation", "remove_presentation", "toggle_fullscreen"]),
    ))
    .expect("failed to run tauri-build");
}
