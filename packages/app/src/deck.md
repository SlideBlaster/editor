# The deck canvas (deck.ts)

The editing surface. The whole deck as one continuous vertical scroll — every
slide stacked top-to-bottom, all live-editable (ux/deck-navigation.md). This is
the primary surface; the navigator ([deckNav.ts](./deckNav.md)) is secondary.

```
┌ deck (scrolls) ┐
│  [ slide 1 ]   │  each slide = a .deck-slide card painted by paintCanvas,
│  [ slide 2 ]◄──┤  fully interactive; its edit actions are bound to its frame
│  [ slide 3 ]   │  index, so a gesture always edits the slide it lands on.
└────────────────┘
```

- **Zoom wrapper.** Slides sit inside a `.deck-canvas` wrapper; the CSS scales the
  slide width (and the wrapper's gaps/padding) by `--zoom`, which `zoom.ts` sets on
  `#deck`. `#deck` stays the fixed scrollport that pans. Rebuilds replace the
  wrapper, so zoom (on `#deck`) persists; horizontal scroll is preserved alongside
  vertical.
- **Measure first, then paint.** `paintDeck` is async: it resolves every slide's
  layout up front via `resolveLayoutAsync` and the injected `BatchMeasurer` (the DOM
  measurer, [domMeasurer.ts](./domMeasurer.md)), awaiting them all before touching the
  DOM — so the deck never appears half-built. The measurer caches by content, so a
  keystroke-triggered full rebuild only re-measures the node that changed. The
  controller guards against stale async paints with a render sequence ([main.ts](./main.md)).
- **Frame-bound editing.** `bindFrame(actions, index)` wraps the controller's
  frame-addressed `DeckActions` (`select`/`move`/`bind`/`requestCreate`/`remove`/
  `editContent`/`connect`/`selectConnector`/`updateConnector`) into
  the `CanvasActions` one slide expects, so `paintCanvas` is reused unchanged and every
  edit — including an inline content edit — carries its slide.
- **Active tracking.** An `IntersectionObserver` (root = the deck) reports the
  slide with the greatest visible area as `onActiveChange`; the controller uses
  it to move the navigator highlight. One observer per host, disconnected before
  each rebuild (`observers` WeakMap) so removed cards are not retained.
- **Scroll survives rebuild.** An edit re-serializes and re-renders the whole
  deck; `paintDeck` captures and restores `scrollTop` so the view does not jump.
  (Surgical single-card repaint is a later optimisation.)
- **Selection is cheap.** `showSelection` toggles handle outlines across all
  cards without a re-render — a drag may be starting on the element.
- **Handle vs scroll.** Only `.sb-handle` sets `touch-action: none`; touching a
  slide's empty area still scrolls the deck.

Provisional: all slides render live; large decks will want off-screen slides
virtualised/snapshotted once the async DOM measurer lands (roadmap Track 0).
