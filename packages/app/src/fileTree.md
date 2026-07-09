# fileTree

The working-copy file tree (roadmap workstream 2): the panel that makes
documents first-class in the editor — browse, open, create, rename, delete —
all through the Storage port.

## Contract

- `paintFileTree(host, { storage, currentPath, onOpen, onMutate })` — repaints
  the whole panel from a fresh recursive `storage.list` walk. `.git` is hidden;
  directory expansion state survives repaints (per host).
- **Editable** files open via `onOpen`: `*.slideBlaster.md` decks and `*.tikz`
  figures (`isEditablePath`, [workspace.md](./workspace.md)). Other files (assets)
  are listed but inert. The current document is highlighted.
- The title bar carries five create affordances. The four that need a name open
  an **inline field in the tree** (never a popup) — Enter commits, Escape cancels,
  blur commits a non-empty value; a name clash marks the field and keeps it open:
  - **New deck** (▤) writes a minimal valid `*.slideBlaster.md` and opens it.
  - **New figure** (◈) writes a starter `*.tikz` picture body and opens it on the
    canvas (a standalone figure, no frontmatter/heading).
  - **New file** (＋) writes an empty file at an arbitrary path (subfolders
    auto-created by `storage.write`); a deck/figure opens, other files just appear.
  - **New folder** (🗀) seeds `<dir>/.gitkeep` (git does not track empty dirs).
  - **Upload** (⬆) reads chosen files and writes them into the working-copy root,
    binary-safe (`storage.write` takes bytes) — no name entry, so no field.
- **Rename** (✎) edits the path **inline** the same way (copy+delete through the
  port, since Storage has no rename; git detects renames heuristically at diff
  time). **Delete** (×) confirms first via the in-app [dialog](./dialog.md);
  committed history is untouched.
- **Active folder.** Clicking a folder selects it (highlighted); opening a doc
  selects its folder; clicking the tree background clears back to the root. New
  deck/file/folder and uploads land **inside the active folder** (a leading `/`
  in the inline name overrides to the root), and the create field shows the
  target folder as a prefix. The selection is validated each repaint and dropped
  if the folder no longer exists.
- **Drag to move.** File **and folder** rows are draggable; folder rows and the
  tree background are drop targets. Dropping onto a folder moves the item inside
  (auto-expanded); dropping on the background moves it to the root. A folder move
  re-roots all its files; moving a folder into itself or a descendant, or onto a
  colliding path, is refused. A move is copy+delete through the port (no native
  move); the open document and active folder follow the move.
- The inline edit, selection, and expansion state live per host and survive the
  whole-tree repaint.
- Every mutation calls `onMutate` so the controller can repaint dependent views
  (this tree, the git panel). The tree never touches the editor state directly —
  opening goes through `onOpen`.

## Assumptions

- Naming is inline in the tree; only confirm/alert (delete, upload clash) use the
  in-app [dialog](./dialog.md) module — never the browser's `window.*`.
