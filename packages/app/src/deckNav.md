# The deck navigator (deckNav.ts)

The secondary navigation beside the scrolling deck canvas ([deck.ts](./deck.md)): a
**vertical carousel** of slide thumbnails between the editor and the canvas, for jumping
directly to a slide (ux/deck-navigation.md). It edits nothing.

- **Appearance.** A vertical rail (`.deck-rail`); the active thumbnail is centred and
  enlarged, neighbours recede. `setActive` re-centres it (`block: 'center'`).
- Thumbnails are the same `renderSlide` output as the canvas (math and tables included via
  the shared `renderOptions`), scaled down by `.thumb` CSS; they use the cheap sync naive
  layout since they are static (the editable canvas uses the DOM measurer).

Sync is two-way and lives in the controller:

- **Click -> scroll.** A thumbnail click fires `onSelect(index)`; the controller calls
  `deckHandle.scrollToSlide(index)`.
- **Scroll -> highlight.** As the canvas scrolls, the deck's active-slide report reaches
  the controller, which calls `navHandle.setActive(index)`. No re-render — just class
  toggles and a centre-scroll.

The earlier filmstrip style (a flat horizontal rail below the canvas) was removed —
the carousel is the single navigator (see ux/deck-navigation.md).
