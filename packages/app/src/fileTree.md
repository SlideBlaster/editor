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
- **New deck** prompts for a name (subfolders allowed), writes a minimal valid
  document, and opens it. **Rename** is copy+delete through the port (the
  Storage port has no rename; git detects renames heuristically at diff time).
  **Delete** confirms first; committed history is untouched.
- Every mutation calls `onMutate` so the controller can repaint dependent views
  (this tree, the git panel). The tree never touches the editor state directly —
  opening goes through `onOpen`.

## Assumptions

- Prompt/confirm dialogs are acceptable M3 chrome; a modeless UI can replace
  them without changing this contract.
