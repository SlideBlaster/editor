# home (projects landing)

The single entry surface: the list of projects (each a repo / working copy) with
open, create, and delete. Platform-agnostic DOM, so both shells reuse it; the
shell owns persistence (the [project registry](./projects.md)) and working-copy
creation and passes them in as callbacks.

## Contract

- `renderHome(root, { projects, onOpen, onCreate, onDelete })` replaces `root`'s
  children with the landing view. Idempotent: call again to re-render (e.g. after
  a delete).
- **Create:** a name field + button; submitting calls `onCreate(name)` (the shell
  creates the project and opens it). **Open:** each project card calls
  `onOpen(id)`. **Delete:** a per-card button, confirmed via an in-app
  [dialog](./dialog.md), calls `onDelete(id)`.
- Empty state prompts the user to create their first project. Cards show the name
  and a coarse "opened … ago".
- Styling: `home.css`, using the design tokens `app.css` defines on `:root`, so
  it themes light/dark with the editor. It imports `app.css` for those tokens; it
  never edits the editor chrome.

The shell (`web-shell/main.ts`) wires the callbacks: create/open route to the
editor (reload-based), delete re-renders the list.
