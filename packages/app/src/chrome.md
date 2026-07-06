# workspace chrome (chrome.ts)

The shared app-shell markup both shells mount identically. `renderChrome(root, {
shellTag })` writes the workspace DOM into `root`: the app bar (title, tools,
export actions, a per-shell `shellTag` badge), the side panel (file tree +
source control; hidden until a shell wires ports), the code editor pane, the
deck canvas, the navigator rail, the zoom control, and the error/status bars.

It exists so the two shells share one DOM structure instead of each carrying the
markup in its own `index.html`. The element IDs the controller
([createApp.ts](./createApp.md)) queries (`#deck`, `#code`, `#deck-rail`, `#props`,
`#zoom-control`, `#export-actions`, `#connect-toggle`, `#undo`, `#redo`, `#status`,
`#error`, `#doc-title`, `#zoom-readout`, `#side-panel`, `#file-tree`,
`#git-panel`, `#editor-head`) are defined here and must stay in sync with that
controller. `#editor-head` shows the path of the open document. `shellTag` is
the only per-shell text (e.g. "web-shell · M3"); it is HTML-escaped.

Between the panes sit two drag handles — `#side-resizer` (file panel | editor)
and `#editor-resizer` (editor | slide canvas) — wired by
[resizer.ts](./resizer.md) to make the widths draggable. They must stay in the
markup in that sibling order, since the CSS collapses `#side-resizer` with the
side panel when it is hidden.
