# dialog

In-app modal dialogs: promise-based replacements for the browser's
`window.confirm` / `window.prompt` / `window.alert`, themed with the editor's
design tokens so they match the rest of the UI in light and dark.

## Contract

- `confirmDialog({ title?, message, confirmLabel?, cancelLabel?, danger? })` —
  resolves `true` if the user confirms, `false` if they dismiss. `danger` styles
  the confirm button as destructive.
- `promptDialog({ title?, message?, label?, initialValue?, placeholder?, confirmLabel?, cancelLabel? })`
  — shows a single text input; resolves the entered string, or `null` if
  dismissed. (An empty confirmed value resolves as `''`, distinct from `null`.)
- `alertDialog({ title?, message, confirmLabel? })` — one acknowledge button;
  resolves when dismissed.

## Behaviour

- Built on the native `<dialog>` element via `showModal()`, so it lives in the
  top layer (no z-index fights), traps focus, and is `aria-modal` for free.
- **Confirm** paths: the confirm button (or Enter, via a `method="dialog"` form).
  **Dismiss** paths: the Cancel button, Escape, or a backdrop click — all resolve
  as a non-confirm and leave no trace.
- Only one dialog exists at a time; opening a new one settles any open dialog as
  a dismissal. The element is removed from the DOM on close.
- Styling lives in `app.css` (`.sb-dialog*`), using the `:root` design tokens; a
  short entrance animation is disabled under `prefers-reduced-motion`.

Generic chrome with no knowledge of its callers; used by [fileTree](./fileTree.md)
(new deck / rename / delete) and [home](./home.md) (delete project).
