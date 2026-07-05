# workspace chrome (chrome.ts)

The shared app-shell markup both shells mount identically. `renderChrome(root, {
shellTag })` writes the workspace DOM into `root`: the app bar (title, tools,
export actions, a per-shell `shellTag` badge), the code editor pane, the deck
canvas, the navigator rail, the zoom control, and the error/status bars.

It exists so the two shells share one DOM structure instead of each carrying the
markup in its own `index.html`. The element IDs the controller
([createApp.ts](./createApp.md)) queries (`#deck`, `#code`, `#deck-rail`, `#props`,
`#zoom-control`, `#export-actions`, `#connect-toggle`, `#undo`, `#redo`, `#status`,
`#error`, `#doc-title`, `#zoom-readout`) are defined here and must stay in sync with
that controller. `shellTag` is the only per-shell text (e.g. "web-shell · M2"); it
is HTML-escaped.
