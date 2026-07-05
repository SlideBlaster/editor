# web-shell entry (main.ts)

The reactive render + edit controller. Runs the editor engine unchanged in the
browser and keeps a **two-way** loop between the source text and the slides, both
sharing one source of truth (the `.slideBlaster.md` text, A1).

```
text -> render (W2):   code pane -> fromMarkdown -> resolveLayoutAsync -> renderSlide
canvas -> text (W4):   gesture   -> E1 edit op   -> toMarkdown         -> code pane
export:                deck       -> renderSlide  -> browser export     -> PDF / .html
```

- **The canvas is the deck.** `paintDeck` ([deck.ts](./deck.md)) stacks every slide
  in one continuous vertical scroll; each is live-editable. A `deckNav`
  ([deckNav.ts](./deckNav.md)) rail jumps between slides. See
  ux/deck-navigation.md.
- **Frame-addressed edits.** `DeckActions` carry the frame the gesture landed on:
  `move -> moveNodeTo`, `create -> createNode`, `remove -> deleteNode`. Each applies
  to the last good parsed document, swaps the one edited frame (`withFrame`),
  re-serializes with `toMarkdown`, pushes the new source into the code pane
  (`setValue`), and re-renders.
- **Selection is cheap.** `select` only toggles handle outlines via
  `deckHandle.showSelection`; it must not re-render, or it would destroy the
  element a drag started on. Selection is `{ frame, name }` — names are unique per
  slide only.
- **Scroll <-> navigator sync.** The deck reports the slide most in view
  (`onActiveChange` -> `state.active` -> `navHandle.setActive`); a navigator click
  (`onSelect`) scrolls the deck (`deckHandle.scrollToSlide`). Neither re-renders.
- **Navigator style setting.** `state.navStyle` is `filmstrip | carousel`, persisted
  in `localStorage` (`sb.navStyle`). Each style has its own slot — filmstrip is the
  horizontal `#deck-strip` below the canvas, carousel is the vertical `#deck-rail`
  between the editor and the canvas; `applyNavPlacement` shows one and hides the
  other. The toggle only re-slots the navigator — the canvas, its scroll, and the
  active slide are untouched.
- **Delete key** removes the selection, except while typing in the code pane.
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
