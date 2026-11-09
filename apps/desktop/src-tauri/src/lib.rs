//! Thin Tauri host for SlideBlaster 0.2.0-alpha (design D9). It owns only native things:
//! the window, menus, the open-folder dialog, the presenter windows and the `sb serve`
//! sidecar. The webview is pointed at the sidecar's own origin, so the TypeScript UI
//! speaks `session/1` and `/cap` to it directly; nothing here parses decks or edits files.
//!
//! Defaults (revisitable): the sidecar binary is `$SB_BIN`, else `sb` beside this
//! executable, else `sb` on `PATH`; the web UI is `$SB_WEB`, else the repository's
//! `hosts/web` (a bundled copy is a packaging step). The port is chosen once per run and
//! reused when the sidecar is restarted, so the page's WebSocket reconnect heals it.

use std::io::{BufRead, BufReader};
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::Duration;

mod presentations;

use presentations::{display_name, parse_args, Store};
use tauri::menu::{CheckMenuItemBuilder, MenuBuilder, MenuItemBuilder, SubmenuBuilder};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, Manager, RunEvent, WebviewUrl, WebviewWindowBuilder, WindowEvent};
use tauri_plugin_dialog::DialogExt;

const TRAY_ID: &str = "main";

#[derive(Default)]
struct Sidecar {
    child: Option<Child>,
    folder: Option<PathBuf>,
    port: u16,
    /// Bumped on every (re)start so stale watcher threads stand down.
    generation: u64,
    /// Known presentations, persisted in the app config dir.
    presentations: Store,
}

type Shared = Arc<Mutex<Sidecar>>;

fn free_port() -> u16 {
    TcpListener::bind("127.0.0.1:0").and_then(|l| l.local_addr()).map(|a| a.port()).unwrap_or(0)
}

fn sb_binary() -> PathBuf {
    if let Some(p) = std::env::var_os("SB_BIN") {
        return PathBuf::from(p);
    }
    if let Ok(exe) = std::env::current_exe() {
        let beside = exe.with_file_name(if cfg!(windows) { "sb.exe" } else { "sb" });
        if beside.exists() {
            return beside;
        }
    }
    PathBuf::from("sb")
}

fn web_dir() -> PathBuf {
    std::env::var_os("SB_WEB")
        .map(PathBuf::from)
        .unwrap_or_else(|| Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../hosts/web"))
}

fn status(app: &AppHandle, text: impl Into<String>) {
    let _ = app.emit("sb-status", text.into());
}

/// Start `sb serve` on `port`; wait for `SB_READY`; navigate the main window to it.
fn start(app: &AppHandle, shared: &Shared, folder: PathBuf, restart: bool) {
    let (port, generation) = {
        let mut s = shared.lock().unwrap();
        if let Some(mut old) = s.child.take() {
            let _ = old.kill();
            let _ = old.wait();
        }
        if s.port == 0 {
            s.port = free_port();
        }
        s.folder = Some(folder.clone());
        s.generation += 1;
        // A sub-presentation opened from its parent stays nested under it; only decks the user
        // added (or opened directly) become top-level entries.
        if !restart && (s.presentations.contains(&folder) || !s.presentations.is_nested(&folder)) {
            s.presentations.touch(&folder, presentations::now_ms());
        }
        (s.port, s.generation)
    };
    if !restart {
        refresh_tray(app, shared);
    }
    if !restart {
        status(app, format!("Starting sb serve for {}", folder.display()));
    }
    let spawned = Command::new(sb_binary())
        .arg("serve")
        .arg(&folder)
        .args(["--port", &port.to_string(), "--web"])
        .arg(web_dir())
        .arg("--exit-on-stdin-eof")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn();
    let mut child = match spawned {
        Ok(c) => c,
        Err(e) => return status(app, format!("Could not start sb ({e}); set SB_BIN. failed")),
    };
    let stdout = child.stdout.take().expect("piped stdout");
    // Keep stdin open: closing it is how the sidecar learns the app is gone.
    shared.lock().unwrap().child = Some(child);

    let (app, shared) = (app.clone(), shared.clone());
    std::thread::spawn(move || {
        let mut ready = false;
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            if !ready && line.starts_with("SB_READY") {
                ready = true;
                if let Some(w) = app.get_webview_window("main") {
                    // The `r` parameter makes this a real navigation even when the URL (same fixed
                    // port) is the one already loaded: the editor must open the NEW project, which a
                    // mere reconnect would not do.
                    let url = format!("http://127.0.0.1:{port}/index.html?r={generation}");
                    // On a restart the page is still loaded and reconnects by itself.
                    if !restart {
                        let _ = w.navigate(url.parse().expect("url"));
                    }
                }
            }
        }
        // stdout closed: the sidecar exited. Restart on the same port unless superseded.
        std::thread::sleep(Duration::from_millis(600));
        let (current, folder) = {
            let s = shared.lock().unwrap();
            (s.generation, s.folder.clone())
        };
        if current == generation {
            if let Some(folder) = folder {
                if ready {
                    start(&app, &shared, folder, true);
                } else {
                    status(&app, "sb serve exited before it was ready. Choose another folder. failed");
                }
            }
        }
    });
}

fn choose_folder(app: &AppHandle, shared: &Shared) {
    let (app, shared) = (app.clone(), shared.clone());
    app.clone().dialog().file().set_title("Open a SlideBlaster project folder").pick_folder(move |picked| {
        match picked.and_then(|p| p.into_path().ok()) {
            Some(folder) => start(&app, &shared, folder, false),
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

#[tauri::command]
fn shell_ready(app: AppHandle, state: tauri::State<Shared>) {
    let first = state.lock().unwrap().folder.is_none();
    if !first {
        return;
    }
    let cwd = std::env::current_dir().unwrap_or_default();
    let args = parse_args(std::env::args().skip(1), &cwd);
    // Folder argument, else the most recently opened presentation, else ask.
    let recent = state.lock().unwrap().presentations.most_recent();
    match args.folder.or(recent) {
        Some(folder) => start(&app, state.inner(), folder, false),
        None => {
            status(&app, "Choose a project folder to begin");
            if !args.background {
                choose_folder(&app, state.inner());
            }
        }
    }
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
    start(app, shared, folder, false);
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

/// Create (or focus) a presenter window on the sidecar's origin so BroadcastChannel reaches it.
#[tauri::command]
fn open_presenter(app: AppHandle, state: tauri::State<Shared>, kind: String) -> Result<(), String> {
    let (label, page, title, size) = match kind.as_str() {
        "console" => ("presenter-console", "console.html", "SlideBlaster presenter", (1120.0, 760.0)),
        "audience" => ("presenter-audience", "audience.html", "SlideBlaster audience", (1280.0, 720.0)),
        other => return Err(format!("unknown presenter window {other}")),
    };
    if let Some(existing) = app.get_webview_window(label) {
        // Reload, not just focus: an open window may hold an old page (sidecar restart, new bundle).
        let _ = existing.eval("location.reload()");
        return existing.set_focus().map_err(|e| e.to_string());
    }
    let port = state.lock().unwrap().port;
    let url = format!("http://127.0.0.1:{port}/{page}");
    let window = WebviewWindowBuilder::new(&app, label, WebviewUrl::External(url.parse().map_err(|e| format!("{e}"))?))
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

/// F in the audience window: native fullscreen on and off, on the screen the window is on.
#[tauri::command]
fn toggle_fullscreen(window: tauri::WebviewWindow) -> Result<(), String> {
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

const OPENER_SCRIPT: &str = r#"
window.__SB_SHELL__ = {
  listPresentations: () => window.__TAURI__.core.invoke('list_presentations'),
  openPresentation: (path) => window.__TAURI__.core.invoke('open_presentation', { path }),
  addPresentation: () => window.__TAURI__.core.invoke('add_presentation'),
  removePresentation: (path) => window.__TAURI__.core.invoke('remove_presentation', { path }),
};
window.__SB_WINDOW_OPENER__ = {
  openConsole: () => { window.__TAURI__.core.invoke('open_presenter', { kind: 'console' }); return true; },
  openAudience: () => { window.__TAURI__.core.invoke('open_presenter', { kind: 'audience' }); return true; },
};
"#;

/// `SB_DEBUG_PRESENT=1`: every window reports its state and errors to stdout via
/// `debug_log`, and the main window presses Present by itself. A self-test tool.
fn debug_script() -> String {
    if std::env::var_os("SB_DEBUG_PRESENT").is_none() {
        return String::new();
    }
    r#"
(() => {
  const log = (m) => { try { window.__TAURI__.core.invoke('debug_log', { msg: location.pathname + ': ' + m }); } catch (e) {} };
  window.addEventListener('error', (e) => log('error ' + e.message + ' @' + e.filename + ':' + e.lineno));
  window.addEventListener('unhandledrejection', (e) => log('rejection ' + (e.reason && (e.reason.stack || e.reason))));
  log('loaded; BroadcastChannel=' + typeof BroadcastChannel + ' tauri=' + typeof window.__TAURI__);
  try { const ch = new BroadcastChannel('sb-presenter'); ch.onmessage = (ev) => log('bc ' + JSON.stringify(ev.data).slice(0, 120)); } catch (e) { log('bc fail ' + e); }
  const report = () => {
    const stage = document.getElementById('stage') || document.getElementById('con-current');
    log('state title=' + document.title + ' stage=' + (stage ? stage.innerHTML.length : 'none') + ' where=' + (document.getElementById('con-where')?.textContent ?? '-'));
  };
  setTimeout(report, 4000); setTimeout(report, 9000);
  if (location.pathname.endsWith('index.html') && location.port) {
    setTimeout(() => { const b = document.getElementById('present-btn'); log('present-btn disabled=' + (b && b.disabled)); b && b.click(); }, 5000);
  }
})();
"#.to_string()
}

#[tauri::command]
fn debug_log(msg: String) {
    println!("SB_DEBUG {msg}");
}

pub fn run() {
    let shared: Shared = Arc::new(Mutex::new(Sidecar::default()));
    let exit_shared = shared.clone();
    let single_shared = shared.clone();
    let app = tauri::Builder::default()
        // Must be the first plugin: a second launch hands its argv to the running app and exits.
        .plugin(tauri_plugin_single_instance::init(move |app, argv, cwd| {
            show_main(app);
            if let Some(folder) = parse_args(argv.into_iter().skip(1), Path::new(&cwd)).folder {
                start(app, &single_shared, folder, false);
            }
        }))
        .plugin(tauri_plugin_dialog::init())
        .manage(shared.clone())
        .invoke_handler(tauri::generate_handler![
            open_folder_dialog,
            shell_ready,
            open_presenter,
            debug_log,
            list_presentations,
            open_presentation,
            add_presentation,
            remove_presentation,
            toggle_fullscreen
        ])
        .on_window_event(|window, event| {
            // Closing the main window hides it to the tray; the sidecar keeps running.
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
            // The initialization script runs in every page the window loads (the sb serve page included).
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
            let mut s = exit_shared.lock().unwrap();
            s.generation += 1; // no restarts while shutting down
            if let Some(mut child) = s.child.take() {
                let _ = child.kill();
                let _ = child.wait();
            }
        }
    });
}
