# Text-style toolbar (styleToolbar.ts)

The app-bar `#text-actions` group: a theme-styles dropdown plus Bold / Italic /
Underline / Strike buttons — the toolbar half of style-in-place
(`design/ux/style-in-place.md`).

## Contract

- **`mountStyleToolbar(host, state, actions) -> { refresh() }`** — builds the controls
  once; `refresh()` re-reads the dropdown from `state` (call on render and on
  selection change — both cheap, no repaint).
- **Format buttons** act on the live selection inside the open rich inline editor
  (`.sb-inline-editor[data-rich]`, found via the DOM — no controller plumbing) through
  `document.execCommand('bold'|'italic'|'underline'|'strikeThrough')`, the same path
  as native Ctrl+B/I/U; the editor's read-back canonicalizes the output into
  html-dialect runs (the default dialect for new canvas styling). Buttons
  `preventDefault` on mousedown so a click never blurs the editor (blur = commit) or
  drops its selection. Pressed-state follows the caret on rAF-coalesced
  `selectionchange` via `queryCommandState` — active only when the whole selection
  carries the style (Docs semantics), including the collapsed-caret pending style.
  Disabled when no rich editor is open or the selection is outside it.
- **Styles dropdown**: `state.classes()` (the active theme's role classes) applied to
  the _selected node_ via `actions.setStyleClass` (engine `setNodeStyleClass` through
  the standard commit: one undo step, source splice, repaint). `state.currentClass()`
  returns the node's class, `null` for an unclassed node, or `undefined` for no
  selection (dropdown disables). Opening the dropdown focuses it, which blurs — and
  therefore commits — an open editor first; the class then applies to the still-
  selected node (the natural ordering).

## Invariants

- The module owns no model state; everything is read through the two getters at
  refresh time, so it can never go stale ahead of its callers.
- Styling emits only in-subset constructs (b/i/u/s and theme classes).
