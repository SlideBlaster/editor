//! Thin Tauri host for SlideBlaster. The editor is the app's own bundled page and the Haskell
//! core runs inside that page as WebAssembly (milestone W-web): there is no server, no socket and
//! no helper process. This shell owns only native things: the window, menus, the open-folder
//! dialog, the presenter windows, and the project folder itself (list, read, conditional write,
//! watch). Nothing here parses decks or decides edits.
//!
//! Two jobs cannot run in a page, compiling a figure and printing a PDF: each is one run of the
//! `sb` command-line tool (`tools.rs`).

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::Duration;

mod presentations;
mod project;
mod tools;

use presentations::{display_name, parse_args, Store};
use tauri::menu::{CheckMenuItemBuilder, MenuBuilder, MenuItemBuilder, SubmenuBuilder};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, Manager, RunEvent, WebviewUrl, WebviewWindowBuilder, WindowEvent};
use tauri_plugin_dialog::DialogExt;

const TRAY_ID: &str = "main";
/// How often the open project is checked for changes made outside the editor.
const WATCH_EVERY: Duration = Duration::from_millis(1000);

#[derive(Default)]
struct Shell {
    /// The open project folder.
    folder: Option<PathBuf>,
    /// Bumped whenever another project opens, so the previous project's watcher stands down.
    generation: u64,
    /// Known presentations, persisted in the app config dir.
    presentations: Store,
}

type Shared = Arc<Mutex<Shell>>;

fn status(app: &AppHandle, text: impl Into<String>) {
    let _ = app.emit("sb-status", text.into());
}

/// Open a project folder: remember it, watch it, and (unless the page is asking for its first
/// project itself) load the editor afresh so it opens the new project.
fn start(app: &AppHandle, shared: &Shared, folder: PathBuf, reload: bool) {
    let generation = {
        let mut s = shared.lock().unwrap();
        s.folder = Some(folder.clone());
        s.generation += 1;
        // A sub-presentation opened from its parent stays nested under it; only decks the user
        // added (or opened directly) become top-level entries.
        if s.presentations.contains(&folder) || !s.presentations.is_nested(&folder) {
            s.presentations.touch(&folder, presentations::now_ms());
        }
        s.generation
    };
    refresh_tray(app, shared);
    watch(app, shared, folder, generation);
    if reload {
        if let Some(w) = app.get_webview_window("main") {
            // A real navigation: the editor must drop the old project's state entirely.
            let _ = w.eval(&format!("location.replace('index.html?r={generation}')"));
        }
    }
}

/// Tell the page which project files changed outside the editor, until another project opens.
fn watch(app: &AppHandle, shared: &Shared, folder: PathBuf, generation: u64) {
    let (app, shared) = (app.clone(), shared.clone());
    std::thread::spawn(move || {
        let mut before = project::scan(&folder);
        loop {
            std::thread::sleep(WATCH_EVERY);
            if shared.lock().unwrap().generation != generation {
                return;
            }
            let now = project::scan(&folder);
            let paths = project::changed(&before, &now);
            if !paths.is_empty() {
                let _ = app.emit("sb-project-changed", serde_json::json!({ "paths": paths }));
            }
            before = now;
        }
    });
}

/// The open project folder. The first call decides it: the folder argument, else the most recently
/// opened presentation, else the user is asked.
fn project_folder(app: &AppHandle, shared: &Shared) -> Result<PathBuf, String> {
    if let Some(folder) = shared.lock().unwrap().folder.clone() {
        return Ok(folder);
    }
    let cwd = std::env::current_dir().unwrap_or_default();
    let args = parse_args(std::env::args().skip(1), &cwd);
    let recent = shared.lock().unwrap().presentations.most_recent();
    match args.folder.or(recent) {
        Some(folder) => {
            start(app, shared, folder.clone(), false);
            Ok(folder)
        }
        None => {
            if !args.background {
                choose_folder(app, shared);
            }
            Err("Choose a project folder to begin (File, Open Folder)".into())
        }
    }
}

fn raw_body<'a>(request: &'a tauri::ipc::Request<'_>) -> Result<&'a [u8], String> {
    match request.body() {
        tauri::ipc::InvokeBody::Raw(bytes) => Ok(bytes),
        _ => Err("this command takes raw bytes".into()),
    }
}

/// Every project file the core may read, packed as `[key, bytes, ...]` (`project.rs`).
#[tauri::command(async)]
fn project_list(app: AppHandle, state: tauri::State<Shared>) -> Result<tauri::ipc::Response, String> {
    let folder = project_folder(&app, state.inner())?;
    Ok(tauri::ipc::Response::new(project::list_packed(&folder)))
}

/// One project file: packed as one part, or no part when it does not exist.
#[tauri::command(async)]
fn project_read(app: AppHandle, state: tauri::State<Shared>, path: String) -> Result<tauri::ipc::Response, String> {
    let folder = project_folder(&app, state.inner())?;
    let packed = match project::read(&folder, &path) {
        Some(bytes) => project::pack_parts(&[&bytes]),
        None => project::pack_parts(&[]),
    };
    Ok(tauri::ipc::Response::new(packed))
}

/// Body: packed `[path, flag, expected, bytes]`; flag 0 means the file must not exist yet.
#[tauri::command(async)]
fn project_write(app: AppHandle, state: tauri::State<Shared>, request: tauri::ipc::Request<'_>) -> Result<(), String> {
    let folder = project_folder(&app, state.inner())?;
    let parts = project::unpack_parts(raw_body(&request)?).ok_or("malformed write")?;
    let [path, flag, expected, bytes] = parts[..] else { return Err("malformed write".into()) };
    let path = std::str::from_utf8(path).map_err(|_| "path is not allowed")?;
    project::write(&folder, path, (flag == [1]).then_some(expected), bytes)
}

/// Body: packed `[path, bytes]`, a file inside `.slideblaster/cache/`.
#[tauri::command(async)]
fn project_cache_write(app: AppHandle, state: tauri::State<Shared>, request: tauri::ipc::Request<'_>) -> Result<(), String> {
    let folder = project_folder(&app, state.inner())?;
    let parts = project::unpack_parts(raw_body(&request)?).ok_or("malformed write")?;
    let [path, bytes] = parts[..] else { return Err("malformed write".into()) };
    project::write_cache(&folder, std::str::from_utf8(path).map_err(|_| "path is not allowed")?, bytes)
}

/// Compile one figure with the `sb` tool: a `block.render` request in, a `provider_result` body out.
#[tauri::command(async)]
fn render_block(app: AppHandle, state: tauri::State<Shared>, request: String) -> Result<String, String> {
    let folder = project_folder(&app, state.inner())?;
    tools::render_block(&folder, &request)
}

#[derive(serde::Serialize)]
struct PdfExport {
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
    warnings: Vec<String>,
}

/// Print the deck `entry` (a path inside the project) to a PDF beside it, with the `sb` tool.
#[tauri::command(async)]
fn export_pdf(app: AppHandle, state: tauri::State<Shared>, entry: String, steps: bool) -> PdfExport {
    let failed = |error: String| PdfExport { ok: false, path: None, name: None, error: Some(error), warnings: Vec::new() };
    let folder = match project_folder(&app, state.inner()) {
        Ok(folder) => folder,
        Err(e) => return failed(e),
    };
    if entry.split('/').any(|s| s.is_empty() || s == "." || s == ".." || s == "_up") || entry.contains('\\') {
        return failed("entry must name a deck inside the project".into());
    }
    let deck = entry.split('/').fold(folder.clone(), |p, s| p.join(s));
    match tools::export_pdf(&folder, &deck, steps) {
        Ok(warnings) => {
            let out = tools::pdf_path(&deck);
            PdfExport { ok: true, name: out.file_name().map(|n| n.to_string_lossy().into_owned()), path: Some(tools::plain_path(&out)), error: None, warnings }
        }
        Err(e) => failed(e),
    }
}

fn choose_folder(app: &AppHandle, shared: &Shared) {
    let (app, shared) = (app.clone(), shared.clone());
    app.clone().dialog().file().set_title("Open a SlideBlaster project folder").pick_folder(move |picked| {
        match picked.and_then(|p| p.into_path().ok()) {
            Some(folder) => start(&app, &shared, folder, true),
            None => {
                if shared.lock().unwrap().folder.is_none() {
                    status(&app, "Choose a project folder to begin");
                }
            }
        }
    });
}

#[tauri::command]
fn open_folder_dialog(app: AppHandle, state: tauri::State<Shared>) {
    choose_folder(&app, state.inner());
}

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct PresentationInfo {
    path: String,
    title: String,
    last_opened: u64,
    current: bool,
    /// Decks this presentation includes (`\include`), nested to any depth; derived, never stored.
    children: Vec<presentations::SubPresentation>,
}

fn presentation_infos(shared: &Shared) -> Vec<PresentationInfo> {
    let s = shared.lock().unwrap();
    let current = s.folder.as_ref().map(|f| f.to_string_lossy().into_owned());
    s.presentations
        .list()
        .into_iter()
        .map(|mut p| {
            // Deck titles change while editing: read them fresh, falling back to the stored one.
            if let Some(t) = presentations::folder_title(Path::new(&p.path)) {
                p.title = Some(t);
            }
            let children = presentations::sub_presentations(Path::new(&p.path), current.as_deref());
            PresentationInfo { title: display_name(&p), current: current.as_deref() == Some(p.path.as_str()), path: p.path, last_opened: p.last_opened, children }
        })
        .collect()
}

/// Rebuild the tray menu from the current list (called whenever it changes).
fn refresh_tray(app: &AppHandle, shared: &Shared) {
    let Some(tray) = app.tray_by_id(TRAY_ID) else { return };
    if let Ok(menu) = build_tray_menu(app, shared) {
        let _ = tray.set_menu(Some(menu));
    }
}

fn build_tray_menu(app: &AppHandle, shared: &Shared) -> tauri::Result<tauri::menu::Menu<tauri::Wry>> {
    let mut pres = SubmenuBuilder::new(app, "Presentations");
    let infos = presentation_infos(shared);
    if infos.is_empty() {
        pres = pres.item(&MenuItemBuilder::with_id("tray-none", "(none yet)").enabled(false).build(app)?);
    }
    for info in &infos {
        let item = CheckMenuItemBuilder::with_id(format!("tray-pres:{}", info.path), &info.title).checked(info.current).build(app)?;
        pres = pres.item(&item);
    }
    MenuBuilder::new(app)
        .item(&MenuItemBuilder::with_id("tray-open", "Open SlideBlaster").build(app)?)
        .item(&pres.build()?)
        .item(&MenuItemBuilder::with_id("tray-folder", "Open Folder…").build(app)?)
        .separator()
        .item(&MenuItemBuilder::with_id("tray-quit", "Quit").build(app)?)
        .build()
}

fn show_main(app: &AppHandle) {
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.show();
        let _ = w.unminimize();
        let _ = w.set_focus();
    }
}

fn open_folder_or_error(app: &AppHandle, shared: &Shared, path: &str) -> Result<(), String> {
    let folder = PathBuf::from(path);
    if !folder.is_dir() {
        return Err(format!("{path} is not a folder"));
    }
    start(app, shared, folder, true);
    Ok(())
}

#[tauri::command]
fn list_presentations(state: tauri::State<Shared>) -> Vec<PresentationInfo> {
    presentation_infos(state.inner())
}

#[tauri::command]
fn open_presentation(app: AppHandle, state: tauri::State<Shared>, path: String) -> Result<(), String> {
    open_folder_or_error(&app, state.inner(), &path)
}

/// Folder dialog; the chosen folder is added to the list and opened.
#[tauri::command]
fn add_presentation(app: AppHandle, state: tauri::State<Shared>) {
    choose_folder(&app, state.inner());
}

#[tauri::command]
fn remove_presentation(app: AppHandle, state: tauri::State<Shared>, path: String) -> Vec<PresentationInfo> {
    state.lock().unwrap().presentations.remove(&path);
    refresh_tray(&app, state.inner());
    presentation_infos(state.inner())
}

/// Create (or focus) a presenter window. It is one of the app's own pages, so it shares the
/// editor's origin and BroadcastChannel reaches it.
// Not on the main thread: on Windows a window built inside a command that runs there never
// finishes (WebView2 waits for the event loop the command is blocking) and the app freezes.
#[tauri::command(async)]
fn open_presenter(app: AppHandle, kind: String) -> Result<(), String> {
    let (label, page, title, size) = match kind.as_str() {
        "console" => ("presenter-console", "console.html", "SlideBlaster presenter", (1120.0, 760.0)),
        "audience" => ("presenter-audience", "audience.html", "SlideBlaster audience", (1280.0, 720.0)),
        other => return Err(format!("unknown presenter window {other}")),
    };
    if let Some(existing) = app.get_webview_window(label) {
        // Reload, not just focus: an open window may show another project's show.
        let _ = existing.eval("location.reload()");
        return existing.set_focus().map_err(|e| e.to_string());
    }
    let window = WebviewWindowBuilder::new(&app, label, WebviewUrl::App(page.into()))
        .title(title)
        .inner_size(size.0, size.1)
        .initialization_script(&debug_script())
        .build()
        .map_err(|e| e.to_string())?;
    if kind == "audience" {
        fill_other_screen(&app, &window);
    }
    Ok(())
}

/// With a second screen (projector, TV) connected, the audience window fills it, borderless, and the
/// editor and console stay on the screen the editor is on. With one screen it stays a normal window
/// (rehearsing); F in the audience window toggles fullscreen wherever it is.
#[cfg(target_os = "linux")]
fn fill_other_screen(app: &AppHandle, window: &tauri::WebviewWindow) {
    use gtk::prelude::*;
    let Some(main) = app.get_webview_window("main").and_then(|w| w.gtk_window().ok()) else { return };
    let Ok(audience) = window.gtk_window() else { return };
    let display = WidgetExt::display(&main);
    // The editor's screen; unknown (hidden editor) means no guess.
    let Some(here) = main.window().and_then(|w| display.monitor_at_window(&w)) else { return };
    let Some(other) = (0..display.n_monitors()).find(|&i| display.monitor(i).as_ref() != Some(&here)) else { return };
    if let Some(screen) = WidgetExt::screen(&audience) {
        audience.fullscreen_on_monitor(&screen, other);
    }
}

#[cfg(not(target_os = "linux"))]
fn fill_other_screen(_app: &AppHandle, _window: &tauri::WebviewWindow) {}

/// F in the audience window, or the console's button (`label` names the audience window): native
/// fullscreen on and off, on the screen the window is on.
#[tauri::command]
fn toggle_fullscreen(app: AppHandle, window: tauri::WebviewWindow, label: Option<String>) -> Result<(), String> {
    let window = match label {
        Some(label) => app.get_webview_window(&label).ok_or_else(|| format!("no window {label}"))?,
        None => window,
    };
    #[cfg(target_os = "linux")]
    {
        use gtk::prelude::*;
        // Ask GTK, not Tauri: fill_other_screen goes fullscreen behind Tauri's back.
        let gtk_window = window.gtk_window().map_err(|e| e.to_string())?;
        let on = gtk_window.window().is_some_and(|w| w.state().contains(gtk::gdk::WindowState::FULLSCREEN));
        if on { gtk_window.unfullscreen() } else { gtk_window.fullscreen() }
        Ok(())
    }
    #[cfg(not(target_os = "linux"))]
    {
        let on = window.is_fullscreen().map_err(|e| e.to_string())?;
        window.set_fullscreen(!on).map_err(|e| e.to_string())
    }
}

/// Export PDF: show the written PDF in the desktop's default viewer. Only an existing `.pdf` file.
#[tauri::command]
fn open_pdf(path: String) -> Result<(), String> {
    let file = PathBuf::from(&path);
    if file.extension().and_then(|e| e.to_str()) != Some("pdf") || !file.is_file() {
        return Err(format!("not a PDF file: {path}"));
    }
    #[cfg(target_os = "linux")]
    let opener = "xdg-open";
    #[cfg(target_os = "macos")]
    let opener = "open";
    #[cfg(target_os = "windows")]
    let opener = "explorer";
    Command::new(opener).arg(&file).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).spawn().map(|_| ()).map_err(|e| e.to_string())
}

const OPENER_SCRIPT: &str = r#"
window.__SB_SHELL__ = {
  inPage: true,
  listPresentations: () => window.__TAURI__.core.invoke('list_presentations'),
  openPresentation: (path) => window.__TAURI__.core.invoke('open_presentation', { path }),
  addPresentation: () => window.__TAURI__.core.invoke('add_presentation'),
  removePresentation: (path) => window.__TAURI__.core.invoke('remove_presentation', { path }),
  openPdf: (path) => window.__TAURI__.core.invoke('open_pdf', { path }),
};
window.__SB_WINDOW_OPENER__ = {
  openConsole: () => { window.__TAURI__.core.invoke('open_presenter', { kind: 'console' }); return true; },
  openAudience: () => { window.__TAURI__.core.invoke('open_presenter', { kind: 'audience' }); return true; },
};
"#;

/// Self-test tools. `SB_DEBUG_STATUS=1`: every window reports its state and errors to stdout via
/// `debug_log`. `SB_DEBUG_PRESENT=1`: the same, and the main window presses Present by itself.
/// `SB_DEBUG_EVAL=<expression>`: the same, and the editor evaluates the expression once the deck
/// is open and reports its (awaited) value.
fn debug_script() -> String {
    let present = std::env::var_os("SB_DEBUG_PRESENT").is_some();
    let eval = std::env::var("SB_DEBUG_EVAL").ok();
    if !present && eval.is_none() && std::env::var_os("SB_DEBUG_STATUS").is_none() {
        return String::new();
    }
    r#"
(() => {
  const log = (m) => { try { window.__TAURI__.core.invoke('debug_log', { msg: location.pathname + ': ' + m }); } catch (e) {} };
  window.addEventListener('error', (e) => log('error ' + e.message + ' @' + e.filename + ':' + e.lineno));
  window.addEventListener('unhandledrejection', (e) => log('rejection ' + (e.reason && (e.reason.stack || e.reason))));
  log('loaded ' + location.href + ' tauri=' + typeof window.__TAURI__);
  try { const ch = new BroadcastChannel('sb-presenter'); ch.onmessage = (ev) => log('bc ' + JSON.stringify(ev.data).slice(0, 120)); } catch (e) { log('bc fail ' + e); }
  const text = (id) => document.getElementById(id)?.textContent ?? '-';
  const report = () => {
    const stage = document.getElementById('stage') || document.getElementById('con-current');
    log('state status=[' + text('status') + '] conn=' + text('conn') + ' banner=[' + (document.getElementById('banner')?.hidden === false ? text('banner') : '') + ']'
      + ' slides=' + document.querySelectorAll('.deck-slide').length + ' figures=' + document.querySelectorAll('.deck-slide svg, .deck-slide img').length
      + ' decks=' + document.querySelectorAll('.pres-list li').length + ' stage=' + (stage ? stage.innerHTML.length : 'none') + ' where=' + text('con-where'));
  };
  for (const ms of [2000, 5000, 9000, 15000, 25000]) setTimeout(report, ms);
  const expression = EVAL;
  if (expression !== null && !document.title.includes('presenter') && !document.title.includes('audience')) {
    setTimeout(async () => { try { log('eval ' + JSON.stringify(await (0, eval)(expression))); } catch (e) { log('eval threw ' + (e && (e.stack || e))); } }, 6000);
  }
  if (PRESENT) {
    setTimeout(() => { const b = document.getElementById('present-btn'); if (!b) return; log('present-btn disabled=' + b.disabled); b.click(); }, 5000);
  }
})();
"#
    .replace("PRESENT", if present { "true" } else { "false" })
    .replace("EVAL", &eval.map(|e| serde_json::to_string(&e).unwrap_or_else(|_| "null".into())).unwrap_or_else(|| "null".into()))
}

#[tauri::command]
fn debug_log(msg: String) {
    println!("SB_DEBUG {msg}");
}

pub fn run() {
    let shared: Shared = Arc::new(Mutex::new(Shell::default()));
    let exit_shared = shared.clone();
    let single_shared = shared.clone();
    let app = tauri::Builder::default()
        // Must be the first plugin: a second launch hands its argv to the running app and exits.
        .plugin(tauri_plugin_single_instance::init(move |app, argv, cwd| {
            show_main(app);
            if let Some(folder) = parse_args(argv.into_iter().skip(1), Path::new(&cwd)).folder {
                start(app, &single_shared, folder, true);
            }
        }))
        .plugin(tauri_plugin_dialog::init())
        .manage(shared.clone())
        .invoke_handler(tauri::generate_handler![
            open_folder_dialog,
            project_list,
            project_read,
            project_write,
            project_cache_write,
            render_block,
            export_pdf,
            open_presenter,
            debug_log,
            list_presentations,
            open_presentation,
            add_presentation,
            remove_presentation,
            toggle_fullscreen,
            open_pdf
        ])
        .on_window_event(|window, event| {
            // Closing the main window hides it to the tray.
            if let WindowEvent::CloseRequested { api, .. } = event {
                if window.label() == "main" {
                    api.prevent_close();
                    let _ = window.hide();
                }
            }
        })
        .setup(move |app| {
            let config_file = match std::env::var_os("SB_CONFIG_DIR") {
                Some(dir) => PathBuf::from(dir),
                None => app.path().app_config_dir()?,
            }
            .join("presentations.json");
            shared.lock().unwrap().presentations = Store::load(config_file);
            let background = parse_args(std::env::args().skip(1), &std::env::current_dir().unwrap_or_default()).background;

            let open = MenuItemBuilder::with_id("open-folder", "Open Folder…").accelerator("CmdOrCtrl+O").build(app)?;
            let reload = MenuItemBuilder::with_id("reload", "Reload").accelerator("CmdOrCtrl+R").build(app)?;
            let menu = MenuBuilder::new(app)
                .item(&SubmenuBuilder::new(app, "File").item(&open).separator().quit().build()?)
                .item(&SubmenuBuilder::new(app, "Edit").undo().redo().separator().cut().copy().paste().select_all().build()?)
                .item(&SubmenuBuilder::new(app, "View").item(&reload).fullscreen().build()?)
                .build()?;
            app.set_menu(menu)?;
            let handler = shared.clone();
            app.on_menu_event(move |app, event| match event.id().as_ref() {
                "open-folder" => choose_folder(app, &handler),
                "reload" => {
                    if let Some(w) = app.get_webview_window("main") {
                        let _ = w.eval("location.reload()");
                    }
                }
                _ => {}
            });
            let tray_shared = shared.clone();
            let mut tray = TrayIconBuilder::with_id(TRAY_ID)
                .tooltip("SlideBlaster")
                .menu(&build_tray_menu(app.handle(), &shared)?)
                .show_menu_on_left_click(false)
                .on_tray_icon_event(|tray, event| {
                    if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. } = event {
                        show_main(tray.app_handle());
                    }
                })
                .on_menu_event(move |app, event| {
                    let id = event.id().as_ref();
                    match id {
                        "tray-open" => show_main(app),
                        "tray-folder" => {
                            show_main(app);
                            choose_folder(app, &tray_shared);
                        }
                        "tray-quit" => app.exit(0),
                        _ => {
                            if let Some(path) = id.strip_prefix("tray-pres:") {
                                show_main(app);
                                let _ = open_folder_or_error(app, &tray_shared, path);
                            }
                        }
                    }
                });
            if let Some(icon) = app.default_window_icon() {
                tray = tray.icon(icon.clone());
            }
            tray.build(app)?;
            // A projector plugged in while presenting: the audience window moves there, fullscreen.
            #[cfg(target_os = "linux")]
            {
                if let Some(display) = gtk::gdk::Display::default() {
                    let handle = app.handle().clone();
                    display.connect_monitor_added(move |_, _| {
                        if let Some(audience) = handle.get_webview_window("presenter-audience") {
                            fill_other_screen(&handle, &audience);
                        }
                    });
                }
            }
            // The editor page; the initialization script runs each time it loads.
            WebviewWindowBuilder::new(app, "main", WebviewUrl::App("index.html".into()))
                .title("SlideBlaster")
                .visible(!background)
                .inner_size(1360.0, 860.0)
                .min_inner_size(900.0, 600.0)
                .initialization_script(OPENER_SCRIPT)
                .initialization_script(&debug_script())
                .build()?;
            if std::env::var_os("SB_DEBUG_PRESENT").is_some() {
                let handle = app.handle().clone();
                std::thread::spawn(move || {
                    std::thread::sleep(Duration::from_secs(8));
                    if let Some(w) = handle.get_webview_window("main") {
                        let _ = w.eval("let d = 'tauri=' + typeof window.__TAURI__ + ' opener=' + typeof window.__SB_WINDOW_OPENER__; location.hash = encodeURIComponent(d); try { window.__TAURI__.core.invoke('debug_log', {msg: 'probe'}).then(() => location.hash = encodeURIComponent(d + ' OK'), (e) => location.hash = encodeURIComponent(d + ' ERR ' + e)); } catch (e) { location.hash = encodeURIComponent(d + ' THROW ' + e); }");
                        std::thread::sleep(Duration::from_secs(2));
                        println!("SB_DEBUG main url: {:?}", w.url().map(|u| u.to_string()));
                    }
                    for label in ["presenter-console", "presenter-audience"] {
                        println!("SB_DEBUG window {label}: {}", handle.get_webview_window(label).is_some());
                    }
                });
            }
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("error while building tauri application");

    app.run(move |_app, event| {
        // Windows closing must not end the app: it lives in the tray until Quit (exit code Some).
        if let RunEvent::ExitRequested { code: None, api, .. } = &event {
            api.prevent_exit();
        }
        if let RunEvent::Exit = event {
            exit_shared.lock().unwrap().generation += 1; // the watcher stands down
        }
    });
}

