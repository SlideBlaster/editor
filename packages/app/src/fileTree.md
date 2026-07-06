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
- The title bar carries four create affordances (each an in-app
  [dialog](./dialog.md) where it needs input):
  - **New deck** (▤) writes a minimal valid `*.slideBlaster.md` and opens it.
  - **New file** (＋) writes an empty file at an arbitrary path (subfolders
    auto-created by `storage.write`); a deck opens, other files just appear.
  - **New folder** (🗀) seeds `<dir>/.gitkeep` (git does not track empty dirs).
  - **Upload** (⬆) reads chosen files and writes them into the working-copy root,
    binary-safe (`storage.write` takes bytes).
- **Rename** is copy+delete through the port (the Storage port has no rename; git
  detects renames heuristically at diff time). **Delete** confirms first;
  committed history is untouched. Name clashes surface an in-app alert.
- Every mutation calls `onMutate` so the controller can repaint dependent views
  (this tree, the git panel). The tree never touches the editor state directly —
  opening goes through `onOpen`.

## Assumptions

- Naming/confirmation prompts go through the in-app [dialog](./dialog.md) module,
  not the browser's `window.prompt/confirm/alert`.
