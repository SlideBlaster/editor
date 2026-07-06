# pane resizers (resizer.ts)

Makes the workspace panes draggable in width. `enableResizers(root)` wires the
two gutters the chrome ([chrome.md](./chrome.md)) renders — `#side-resizer`
(file panel | editor) and `#editor-resizer` (editor | slide canvas) — so the
user can drag the file tree, the code editor, and (by consequence) the slide
canvas wider or narrower.

## Contract

- The workspace is a CSS grid: the side panel and editor tracks size to the
  custom properties `--sb-side-w` / `--sb-editor-w`; the slide canvas is the
  flexible `1fr` track. Dragging a gutter sets the width property of the pane on
  its left, so the canvas absorbs the difference.
- `enableResizers(root)` is called once by [createApp.ts](./createApp.md) after
  the chrome is rendered. It is a no-op if `.workspace` is absent.
- Widths are clamped: each pane keeps a px floor, and no pane may grow past the
  point where the canvas would fall below a minimum width.
- Widths persist to `localStorage` (`sb.width.side`, `sb.width.editor`),
  best-effort — private mode or quota failures degrade to the CSS defaults.
- Double-clicking a gutter drops the override (reverts to the CSS default width).
- Gutters are focusable `role="separator"` elements; Arrow Left/Right nudge the
  boundary for keyboard users.

## Invariants

- The properties are set on `.workspace`, so they survive deck/panel rebuilds.
- The module owns width only; visibility of the side panel (hidden until ports
  are wired) stays the controller's job — the CSS collapses `#side-resizer`
  alongside a hidden side panel.
