# web-shell entry (main.ts)

The browser shell's entry point — deliberately thin. It mounts the shared editor
app ([@slideblaster/app](../../app/src/index.md)) into the page's `#app` element and
tags the app bar with `web-shell · M2`.

All of the editor UI and behaviour lives in `@slideblaster/app` so it is shared with
`desktop-shell` (implement once). This file's future job is to build the **browser**
port adapters (IndexedDB/FSA storage, isomorphic-git + CORS proxy, browser export)
and hand them to `createApp`; that wiring lands with the adapters (M3+). Today it
passes no adapters — the app runs the bundled in-memory sample.

The KaTeX offline stylesheet and the workspace styles come from the app package;
this shell only owns `vite.config.ts`, `index.html`, and this entry.
