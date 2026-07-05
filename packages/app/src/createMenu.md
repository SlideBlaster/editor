# creation menu (createMenu.ts)

The cursor-anchored popover for adding an element (W5, ux/creation-menu.md). A single,
self-contained overlay — the primary, ergonomic path for insertion (the code pane is the
secondary path).

- **One entry point.** `openCreationMenu(clientX, clientY, { items, onPick, onDismiss })`
  mounts a fixed-position popover on `document.body` at the client point (nudged back
  inside the viewport if it would overflow), focuses a filter input, and renders the
  catalogue. `closeCreationMenu()` dismisses any open menu; only one exists at a time.
- **Type to filter.** The input filters `items` by a case-insensitive label substring.
  ArrowUp/Down move the active item; Enter picks the active one; a click picks; pointer
  hover tracks the active item.
- **Pick vs dismiss.** Picking closes the menu and fires `onPick(id)` — the controller
  then inserts the element, selects it, and opens it in edit mode. Escape or an outside
  `pointerdown` fires `onDismiss()` and closes with **no trace** — an exploratory summon
  never alters the document.
- **Catalogue is the controller's.** This module is generic over `MenuItem`
  (`{ id, label, hint? }`); the element catalogue and the id -> `createNode` mapping live
  in [main.ts](./main.md), because insertion is a document edit, not a menu concern.
- **Invocation** is wired to a double-click on the empty canvas (replacing the old
  direct-insert stub). Other invocations (a shortcut, a persistent "+") stay open in the
  spec.
