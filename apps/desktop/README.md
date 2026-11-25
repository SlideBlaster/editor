# SlideBlaster desktop

A Tauri 2 app. The editor is the app's own embedded page and the Haskell core runs inside that page
as WebAssembly: the app starts no server and opens no port. The shell owns the window, menus, the
open-folder dialog, the presenter windows, the tray, and the project folder (list, read,
conditional write, watch; `src-tauri/src/project.rs`).

Two jobs cannot run in a page and are one run of the `sb` command-line tool each
(`src-tauri/src/tools.rs`): compiling a figure (`sb render DIR`, LaTeX) and Export PDF
(`sb build --pdf`, headless Chrome). Without the tool the editor still works; figures stay
placeholders that say so. The tool is `$SB_BIN`, else `sb` beside the executable, else `sb` on
`PATH`; `$SB_WEB` (default: this repository's `hosts/web`) is where it finds the offline viewer.

Build:

    (cd ../../hosts/web && npm ci && npm run build)   # the editor
    ../../scripts/build-wasm.sh                        # the core (needs the wasm32-wasi GHC)
    ./stage-ui.sh                                      # copy both into ui-dist/, which the app embeds
    cd src-tauri && cargo build --release
    ./target/release/slideblaster-desktop /path/to/project

With no folder argument the app opens the most recently opened presentation (the list lives in
`presentations.json` in the app config dir; `SB_CONFIG_DIR` overrides it) and asks only when the
list is empty. It lives in the system tray: closing the window hides it, Quit in the tray menu
exits; a second launch focuses the running app (and switches to a folder argument); `--background`
starts hidden. The editor shows a presentations sidebar (Ctrl+B). `install-desktop.sh [--autostart]`
installs a launcher and desktop entry.

Windows: `cargo build --release --target x86_64-pc-windows-gnu` (from Linux, with mingw); ship the
exe with `WebView2Loader.dll` beside it. Without a native `sb.exe` beside the app, a project folder
inside WSL (`\\wsl.localhost\<distro>\...`) uses the Linux `sb` there for figures and PDF, through
`~/.local/bin/slideblaster-tool` in that distribution.

Self-test: `SB_DEBUG_STATUS=1` prints each window's state and errors to stdout;
`SB_DEBUG_EVAL=<expression>` also evaluates an expression in the editor and prints its value;
`SB_DEBUG_PRESENT=1` also presses Present.
