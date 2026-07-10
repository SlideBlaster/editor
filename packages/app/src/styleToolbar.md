# Text-style toolbar (styleToolbar.ts)

The app-bar `#text-actions` group: a theme-styles dropdown, a per-node font-size control,
plus Bold / Italic / Underline / Strike / Highlight buttons — the toolbar half of style-in-place
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
  **Highlight** is the exception: `<mark>` has no native `execCommand`/`queryCommandState`,
  so it delegates to `toggleHighlight`/`isSelectionHighlighted` ([richText.ts](./richText.md))
  — apply still rides `execCommand('hiliteColor')` (undoable; read-back canonicalizes the
  background span to a `mark` run), pressed-state is a DOM check.
- **Styles dropdown**: `state.classes()` (the active theme's role classes) applied to
  the _selected node_ via `actions.setStyleClass` (engine `setNodeStyleClass` through
  the standard commit: one undo step, source splice, repaint). `state.currentClass()`
  returns the node's class, `null` for an unclassed node, or `undefined` for no
  selection (dropdown disables). Opening the dropdown focuses it, which blurs — and
  therefore commits — an open editor first; the class then applies to the still-
  selected node (the natural ordering).
- **Font-size control** (`A-` / numeric field / `A+`): node-grain, pairing with the
  dropdown. `state.fontSize()` returns the selected node's effective size in `cqw` (its
  `font size` override, else the resolved role/base size) plus the theme's modular
  `step` ratio, or `undefined` when nothing is selected (the control disables).
  `A-`/`A+` commit `value / step` / `value * step`; the field commits a typed value (blank
  clears). All go through `actions.setFontSize(cqw | null)`; the controller normalizes a
  value back at the inherited size to a clear (removes the token — class < node). Like the
  dropdown it takes focus (not `preventDefault`), so it blurs+commits an open editor first.

## Invariants

- The module owns no model state; everything is read through the getters at
  refresh time, so it can never go stale ahead of its callers.
- Styling emits only in-subset constructs (b/i/u/s, `mark` (highlight), theme classes, and `font size`).
