# The deck navigator (deckNav.ts)

The secondary navigation beside the scrolling deck canvas
([deck.ts](./deck.md)): a strip of slide thumbnails for jumping directly to a
slide (ux/deck-navigation.md). It edits nothing.

Two styles, chosen by a setting — the same navigator, framed and placed
differently. Each has its own host in the DOM; the controller shows one and
hides the other (`#deck-strip` / `#deck-rail`):

- **filmstrip** — a flat horizontal rail **below the canvas**; the active
  thumbnail is outlined. `setActive` keeps it in view (`block: 'nearest'`).
- **carousel** — a vertical strip **between the editor and the canvas**; the
  active thumbnail is centred and enlarged, neighbours recede. `setActive`
  re-centres it (`block: 'center'`).

The `style` prop only selects the scroll axis for `setActive`; all appearance
comes from the host's own class (`.deck-rail` / `.deck-strip`).

Sync is two-way and lives in the controller:

- **Click -> scroll.** A thumbnail click fires `onSelect(index)`; the controller
  calls `deckHandle.scrollToSlide(index)`.
- **Scroll -> highlight.** As the canvas scrolls, the deck's active-slide report
  reaches the controller, which calls `navHandle.setActive(index)`. No re-render
  — just class toggles (and a centre-scroll in carousel style).

Switching style rebuilds only the navigator, not the canvas, so scroll position
and the active slide are untouched. Thumbnails are the same `renderSlide` output
as the canvas, scaled down by `.thumb` CSS.
