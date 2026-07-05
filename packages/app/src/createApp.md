# shared app controller (createApp.ts)

The reactive render + edit controller, exported as `createApp(root, opts?)` and
mounted identically by both shells (web, desktop). Runs the editor engine unchanged
in any webview and keeps a **two-way** loop between the source text and the slides,
both sharing one source of truth (the `.slideBlaster.md` text, A1). On mount it
renders the [chrome](./chrome.md) into `root` and injects the global stylesheets
(once), then wires everything below. `opts.shellTag` sets the app-bar badge.

```
text -> render (W2):   code pane -> fromMarkdown -> resolveLayoutAsync -> renderSlide
canvas -> text (W4):   gesture   -> E1 edit op   -> toMarkdown         -> code pane
export:                deck       -> renderSlide  -> browser export     -> PDF / .html
```

- **The canvas is the deck.** `paintDeck` ([deck.ts](./deck.md)) stacks every slide
  in one continuous vertical scroll; each is live-editable. A carousel `deckNav`
  ([deckNav.ts](./deckNav.md)) rail jumps between slides. Math renders via KaTeX
  ([math.ts](./math.md)) on every surface. See ux/deck-navigation.md.
- **Frame-addressed edits.** `DeckActions` carry the frame the gesture landed on:
  `move -> moveNodeTo` (also the detach path), `bind -> placeNodeRelative` (E2),
  `requestCreate -> creation menu -> createNode` (W5), `remove -> deleteNode`,
  `editContent -> parseContent + setNodeContent`, `connect -> createConnector` (E4),
  `selectConnector` (connector selection, exclusive with node selection),
  `updateConnector -> updateConnector` (reshape endpoints/waypoints/curves). A connect-mode
  toolbar toggle (`#connect-toggle`, Esc to exit) flips dragging into arrow-drawing;
  Delete removes the selected node or connector (`deleteConnector`). Each applies to the
  last good parsed
  document, swaps the one edited frame (`withFrame`), re-serializes with `toMarkdown`,
  pushes the new source into the code pane (`setValue`), and re-renders.
- **Creation menu (W5).** `requestCreate` opens the cursor-anchored menu
  ([createMenu.ts](./createMenu.md)) with the element `CATALOGUE`; picking inserts a node
  of that kind at the slide point, selects it, and sets `autoEdit` so it opens in edit
  mode next paint. Dismissing leaves the document untouched. Invocation is the
  empty-canvas double-click (was: a direct text-node insert).
- **Undo / redo.** A source-history stack: every `commit` snapshots the pre-edit source
  onto `undoStack` (capped, clears the redo branch); `undo`/`redo` swap sources and sync
  the code pane. Keys `Ctrl/Cmd+Z` and `Ctrl/Cmd+Shift+Z` (or `Ctrl+Y`), plus toolbar
  buttons whose disabled state tracks the stacks. This covers **canvas edits**; typing in
  the code pane keeps the textarea's own native undo (the keyboard handler ignores keys
  while a field is focused). So one menu insertion is one undo step (ux/creation-menu.md).
- **Out-of-subset error state.** An inline edit is re-parsed by `parseContent`, which
  tolerates unsupported constructs by returning error content (source preserved
  verbatim, renders as a marked error — ADR 0015). `setStatus` counts error nodes across
  the deck (`countErrorNodes`) and surfaces the document error state; the git-commit
  gate itself lands with the Git adapter (M4).
- **Selection is cheap.** `select` only toggles handle outlines via
  `deckHandle.showSelection`; it must not re-render, or it would destroy the
  element a drag started on. Selection is `{ frame, name }` — names are unique per
  slide only.
- **Properties panel (E5).** `paintPanel` repaints the [inspector](./properties.md) for
  the current selection — on selection (no deck re-render) and after every render. It
  edits arrow style (`setConnectorOptions`) and node placement (`move`/`bind`); its actions
  are bound to the selected frame. Scoped to arrows + placement for now.
- **Scroll <-> navigator sync.** The deck reports the slide most in view
  (`onActiveChange` -> `state.active` -> `navHandle.setActive`); a navigator click
  (`onSelect`) scrolls the deck (`deckHandle.scrollToSlide`). Neither re-renders.
- **Navigator.** A single carousel rail (`#deck-rail`, the vertical strip between the
  editor and the canvas) painted by `paintDeckNav`; the earlier filmstrip style was
  removed. Repainting the navigator never touches the canvas, its scroll, or the active
  slide.
- **Keyboard.** Delete removes the selected node or connector; undo/redo as above; Esc
  exits connect mode; PageUp/PageDown and Home/End move between slides
  (`deckHandle.scrollToSlide`). All are ignored while a text field (code pane, inline
  editor, menu filter) is focused, so those keep their native behaviour. The zoom control
  also has a **Fit** button (`zoom.fitWidth`).
- **Canvas edits canonicalize.** `toMarkdown` re-emits the whole document in canonical
  form, so a canvas edit normalizes source formatting document-wide (fine for the
  canonical sample; surgical per-frame splicing is a later refinement). `paintDeck`
  preserves scroll position across the rebuild.
- **Tolerant parse.** A malformed manual edit shows an error banner and keeps the last
  good render.
- **DOM measurement (async render).** Node sizes come from the DOM measurer
  ([domMeasurer.ts](./domMeasurer.md)) via `resolveLayoutAsync`, so `render` is async.
  A monotonic `renderSeq` token (passed as `isStale`) drops a slow paint that finishes
  after a newer edit, so rapid typing can't paint a stale layout. The measurer caches by
  content, so a full-deck rebuild only re-measures the node that changed.
- **Export.** The app-bar Print / PDF and Export HTML buttons render every frame with the
  same cached DOM measurements (`collectSlides` -> `renderSlide`), then hand the
  `RenderedSlide[]` to the browser export adapter ([export.ts](./export.md)) — print to
  PDF or download a self-contained presenter `.html`.
- **Styling seam.** `slideStylesheet()` supplies the base layered-DOM rules; the shared
  `SLIDE_TYPE_CSS` ([slideType.ts](./slideType.md)) the proportional type scale; `app.css`
  layers the workspace chrome and the interaction overlay.
