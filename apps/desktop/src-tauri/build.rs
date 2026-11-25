fn main() {
    // Declare the shell's own commands as permissions, granted to the app's pages by capabilities/.
    tauri_build::try_build(tauri_build::Attributes::new().app_manifest(
        tauri_build::AppManifest::new().commands(&["open_folder_dialog", "project_list", "project_read", "project_write", "project_cache_write", "render_block", "export_pdf", "open_presenter", "debug_log",
            "list_presentations", "open_presentation", "add_presentation", "remove_presentation", "toggle_fullscreen", "open_pdf"]),
    ))
    .expect("failed to run tauri-build");
}
