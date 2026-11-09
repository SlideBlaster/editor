# SlideBlaster desktop (alpha)

Thin Tauri 2 shell: window, menus, open-folder dialog, presenter windows, and the `sb serve` sidecar.

    (cd ../../hosts/web && npm ci && npm run build)
    cd src-tauri && SB_BIN=/path/to/sb cargo run -- /path/to/project

`SB_BIN` defaults to `sb` beside the executable, then on `PATH`; `SB_WEB` defaults to `hosts/web`.
With no folder argument the app opens the most recently opened presentation (the list lives in `presentations.json` in the app config dir; `SB_CONFIG_DIR` overrides it) and asks only when the list is empty. It lives in the system tray: closing the window hides it, Quit in the tray menu exits; a second launch focuses the running app (and switches to a folder argument); `--background` starts hidden. The editor shows a presentations sidebar (Ctrl+B) when it runs inside the shell. `install-desktop.sh [--autostart]` installs a launcher and desktop entry. The sidecar uses one port per run and is restarted
on the same port if it exits, so the UI's reconnect banner clears by itself.
