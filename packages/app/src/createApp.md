# shared app controller (createApp.ts)

The reactive render + edit controller, exported as `createApp(root, opts?)` and
mounted identically by both shells (web, desktop). Runs the editor engine unchanged
in any webview and keeps a **two-way** loop between the source text and the slides,
both sharing one source of truth (the `.slideBlaster.md` text, A1). On mount it
renders the [chrome](./chrome.md) into `root` and injects the global stylesheets
(once), then wires everything below. `opts.shellTag` sets the app-bar badge;
`opts.ports` (optional) wires the working copy in — see the working-copy bullet.
`opts.onExitToProjects` (optional) adds a "← Projects" button to the app bar that
returns to the landing ([home.md](./home.md)) — set by shells that switch between
projects.

```
text -> render (W2):   code pane -> fromMarkdown -> resolveLayoutAsync -> renderSlide
canvas -> text (W4):   gesture   -> E1 edit op   -> toMarkdown         -> code pane
export:                deck       -> renderSlide  -> browser export     -> PDF / .html
```

- **The canvas is the deck.** `paintDeck` ([deck.ts](./deck.md)) stacks every slide
  in one continuous vertical scroll; each is live-editable. A carousel `deckNav`
  ([deckNav.ts](./deckNav.md)) rail jumps between slides. Math renders via KaTeX
  ([math.ts](./math.md)) on every surface. See ux/deck-navigation.md.
- **Deck structure edits.** Two edits change the frame list itself, both undoable through
  `commit` like any node edit. `addSlide` appends a blank frame (`withNewFrame`) and reveals
  it (`pendingScroll`, consumed by the next render) — one action behind two triggers, the
  top-bar `#new-slide` button and the carousel's bottom "+ New slide" affordance (`onAdd`).
  Delete removes the active frame (`withoutFrame`) only when nothing on-slide is selected
  **and the carousel holds focus** (the rail is "directly selected" — see Keyboard). Both
  are deck-only (a `.tikz` figure is a single picture) and the last slide is never deletable.
- **Frame-addressed edits.** `DeckActions` carry the frame the gesture landed on:
  `move -> moveNodeTo` (also the detach path), `bind -> placeNodeRelative` (E2),
  `requestCreate -> creation menu -> createNode` (W5), `remove -> deleteNode`,
  `editContent -> parseContent + setNodeContent`, `connect -> createConnector` (E4),
  `selectConnector` (connector selection, exclusive with node selection),
  `updateConnector -> updateConnector` (reshape endpoints/waypoints/curves). A connect-mode
  toolbar toggle (`#connect-toggle`, Esc to exit) flips dragging into arrow-drawing;
  Delete removes the selected node or connector (`deleteConnector`). With nothing on-slide
  selected AND the carousel focused (a slide "directly selected"), Delete removes the whole
  active slide — the one the carousel highlights (`state.active`) — via `withoutFrame`,
  guarding the last slide (a deck keeps at least one) and skipped for a standalone `.tikz`
  figure. When the rail is unfocused its highlight is only a "you are here" indicator, so
  Delete leaves the deck alone. Each applies to the
  last good parsed
  document, swaps the one edited frame (`withFrame`), re-serializes with `toMarkdown`,
  pushes the new source into the code pane (`setValue`), and re-renders.
- **Async repaints yield to an open edit.** The out-of-band re-renders (table compile /
  citation resolve `onReady`) rebuild the deck DOM; while an inline editor is open they
  are held (`renderWhenEditingSettles`) until the edit commits or cancels, so a
  resolving table can never destroy an edit mid-type.
- **Text-style toolbar.** The app-bar `#text-actions` group mounts
  [styleToolbar.ts](./styleToolbar.md): B/I/U/S act directly on the rich inline
  editor's DOM selection (no controller plumbing), while the theme-styles dropdown
  reclassifies the selected node via the engine's `setNodeStyleClass` through the
  standard `commit`. A per-node **font-size** control (A- / value / A+) reads the node's
  effective size (its `font size` override else the theme role/base size) and commits
  `setNodeOptions(withFontSize(...))`; resetting to the inherited size clears the token
  (class < node). `refresh()` runs on every render and on the repaint-free
  `select` path, so the dropdown tracks selection without a redraw.
- **Node-scoped content commit (ADR 0016).** Content edits (`editContent` from the raw
  inline editor, `editContentModel` from the WYSIWYG editor and the column grid
  affordance) take `commitContent` instead
  of the whole-doc `commit`: it swaps the one node's content, then derives both deltas —
  the code pane is spliced at the single changed range (`minimalDiff`,
  [sourceDelta.md](./sourceDelta.md), caret kept) and only that frame's card + thumbnail
  repaint (`deckHandle.repaintFrame` / `navHandle.repaintThumb`). No whole-scene redraw,
  no divergence (the pane ends up byte-identical to `toMarkdown`). Undo/persist unchanged.
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
- **Compile port (tables).** `installTableCompiler(ports.compile, …)` wires the latexml
  Compile port into the shared `renderOptions` ([tableCompiler.md](./tableCompiler.md)).
  `render` schedules a debounced compile of the doc's tables; when one finishes, the
  measurer is reset and the deck re-renders so the table appears at its true size.
  `collectSlides` awaits `ensureTables` first so an export never races the compile.
- **Document codec (deck vs figure).** The on-disk text ⇄ `SlideDocument` mapping is a
  per-open-file `DocCodec` picked by `codecFor(path)`. A **deck** (`.slideBlaster.md`)
  uses `fromMarkdown`/`toMarkdown`. A **figure** (`.tikz`,
  [workspace.md](./workspace.md)) is a bare slide-picture body wrapped as one anonymous
  frame with empty frontmatter — parse is `parsePicture`, serialize is
  `serializePicture` of `frames[0].picture` — so the whole controller (canvas, edit ops,
  undo, code pane) works on it unchanged; the three seam calls (`render`'s parse,
  `commit`, `commitContent`) route through the codec. `openDoc` sets the codec (before
  render) and `applyDocModeChrome` hides deck-only UI for a figure: the `#deck-rail`
  navigator, the presenter-notes column ([deck.md](./deck.md) `notes:false`), theme
  furniture, and the present/export/theme controls. A figure's empty frontmatter makes
  the theme resolve to `default`, and it never clobbers the last-opened-deck memory.
- **Working copy (M3).** With `opts.ports` (`AppPorts`: storage/git/auth from
  [workspace.ts](./workspace.md)) the open document lives in the working copy:
  boot seeds/selects via `bootDocument` and every source change persists through
  the debounced autosave (`persist` in `commit`/`restore`/code-pane `onChange`;
  flushed on doc switch, before a git commit, and on unload — discarded instead
  if the file was deleted or renamed away). The side panel (`#side-panel`)
  reveals the [file tree](./fileTree.md) (open/create/rename/delete; deleting
  the open doc re-boots onto a surviving one) and the
  [git panel](./gitPanel.md) (status / stage-all commit / log, author from the
  Auth port). `#editor-head` shows the open path. Doc switches reset the undo
  stacks and selection. Without ports everything above is absent and the
  bundled sample runs purely in memory (pre-M3 behaviour, still the desktop
  shell's mode until M5).
- **Selection is cheap.** `select` only toggles handle outlines via
  `deckHandle.showSelection`; it must not re-render, or it would destroy the
  element a drag started on. Selection is `{ frame, name }` — names are unique per
  slide only.
- **Properties panel (E5).** `paintPanel` repaints the [inspector](./properties.md) for
  the current selection — on selection (no deck re-render) and after every render. It
  edits arrow style (`setConnectorOptions`) and node placement (`move`/`bind`); its actions
  are bound to the selected frame. Scoped to arrows + placement for now.
- **Scroll <-> navigator sync.** Two paths, one owner. `setActiveSlide(index)` is the sole
  writer of "which slide is current": it sets `state.active`, moves the highlight
  (`navHandle.setActive`), and syncs the step control. A scroll report drives it
  (`onActiveChange -> setActiveSlide`, no scroll-back — the scroll is what fired it). An
  explicit jump (carousel click/arrow, PageUp/Down, Home/End) drives it through
  `selectSlide`, which sets the highlight **immediately** and _then_ best-effort re-centres
  the canvas (`deckHandle.scrollToSlide`). The immediate highlight fixes selecting a slide
  already in view — the scroll can't move, so a scroll-driven highlight would never update.
  Neither path re-renders.
- **Navigator.** A single carousel rail (`#deck-rail`, the vertical strip between the
  editor and the canvas) painted by `paintDeckNav`; the earlier filmstrip style was
  removed. Repainting the navigator never touches the canvas, its scroll, or the active
  slide.
- **Keyboard.** Delete removes the selected node or connector, else the active slide when
  the carousel holds focus (above); undo/redo as above; Esc exits connect mode; PageUp/Down
  and Home/End move between slides through `selectSlide` (so the highlight follows even when
  the canvas can't scroll further). ArrowUp/Down also move between slides, but only while the
  carousel rail is focused — handled inside [deckNav.ts](./deckNav.md), so arrow keys stay
  free for the canvas elsewhere. All are ignored while a text field (code pane, inline
  editor, menu filter) is focused, so those keep their native behaviour. The zoom control
  also has a **Fit** button (`zoom.fitWidth`).
- **Canvas edits canonicalize.** `toMarkdown` re-emits the whole document in canonical
  form. Coarse ops (`commit`) then push the whole source and rebuild the deck (`paintDeck`
  preserves scroll). Content edits (`commitContent`) instead splice only the changed range
  into the code pane and repaint only the touched frame (ADR 0016, above); the canonical
  form still governs, so non-canonical source normalizes on first touch.
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
- **Overlay step preview (ADR 0018).** `state.preview` (`{ frame, step } | null`) previews
  one slide at one build step; every other slide renders all-visible. The app-bar
  `#step-control` (shown only when the active slide has >1 step) and the `,`/`.` keys scrub
  it through All -> 1 -> … -> N; a scrub repaints just that frame (`repaintFrame` with a
  `step` in its ctx), and scrolling to another slide clears the preview. Whole-node reveal
  is edited in the properties panel (`setNodeOverlay`); export expands to one page per step
  via `slideStepCount` in `collectSlides`.
