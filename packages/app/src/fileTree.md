# fileTree

The working-copy file tree (roadmap workstream 2): the panel that makes
documents first-class in the editor — browse, open, create, rename, delete —
all through the Storage port.

## Contract

- `paintFileTree(host, { storage, currentPath, onOpen, onMutate })` — repaints
  the whole panel from a fresh recursive `storage.list` walk. `.git` is hidden;
  directory expansion state survives repaints (per host).
- `*.slideBlaster.md` files open via `onOpen`; other files (assets) are listed
  but inert. The current document is highlighted.
- The title bar carries four create affordances. The three that need a name open
  an **inline field in the tree** (never a popup) — Enter commits, Escape cancels,
  blur commits a non-empty value; a name clash marks the field and keeps it open:
  - **New deck** (▤) writes a minimal valid `*.slideBlaster.md` and opens it.
  - **New file** (＋) writes an empty file at an arbitrary path (subfolders
    auto-created by `storage.write`); a deck opens, other files just appear.
  - **New folder** (🗀) seeds `<dir>/.gitkeep` (git does not track empty dirs).
  - **Upload** (⬆) reads chosen files and writes them into the working-copy root,
    binary-safe (`storage.write` takes bytes) — no name entry, so no field.
- **Rename** (✎) edits the path **inline** the same way (copy+delete through the
  port, since Storage has no rename; git detects renames heuristically at diff
  time). **Delete** (×) confirms first via the in-app [dialog](./dialog.md);
  committed history is untouched.
- **Drag to move.** File rows are draggable; folder rows and the tree background
  are drop targets. Dropping a file onto a folder moves it inside (the folder
  auto-expands); dropping on the background moves it to the root. A move is
  copy+delete through the port; a destination name clash is refused.
- The inline edit state (which item, which kind) lives per host and survives the
  whole-tree repaint, alongside directory expansion state.
- Every mutation calls `onMutate` so the controller can repaint dependent views
  (this tree, the git panel). The tree never touches the editor state directly —
  opening goes through `onOpen`.

## Assumptions

- Naming is inline in the tree; only confirm/alert (delete, upload clash) use the
  in-app [dialog](./dialog.md) module — never the browser's `window.*`.
