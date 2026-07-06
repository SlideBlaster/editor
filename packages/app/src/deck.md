# The deck canvas (deck.ts)

The editing surface. The whole deck as one continuous vertical scroll — every
slide stacked top-to-bottom, all live-editable (ux/deck-navigation.md). This is
the primary surface; the navigator ([deckNav.ts](./deckNav.md)) is secondary.

```
┌ deck (scrolls) ────────────┐
│  [ slide 1 ] [ notes 1 ]   │  each frame = a .deck-row: a .deck-slide card and a
│  [ slide 2 ] [ notes 2 ]◄──┤  .deck-note card, both painted by paintCanvas and fully
│  [ slide 3 ] [  + add  ]   │  interactive. Edits are addressed by (frame, surface),
└────────────────────────────┘  so a gesture on the notes card edits frame.notes.
```

- **Two columns, one scroll (ADR 0019).** Every frame is a `.deck-row` holding the
  audience slide (`.deck-slide`) and its presenter-notes sidecar (`.deck-note`), side by
  side and scrolling together. A frame with no `notes` shows a `.deck-note-empty`
  placeholder with an "Add notes" button (`actions.addNotes(frame)` seeds an empty notes
  picture and opens it for editing). The notes card is the same interactive canvas as the
  slide — nothing about `paintCanvas` changes, only which picture and actions it is given.

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
- **Surface-bound editing.** `bindFrame(actions, index, surface)` wraps the controller's
  `(frame, surface)`-addressed `DeckActions` (`select`/`move`/`bind`/`requestCreate`/
  `remove`/`editContent`/`connect`/`selectConnector`/`updateConnector`/`addNotes`) into
  the `CanvasActions` one card expects, so `paintCanvas` is reused unchanged and every
  edit carries both its frame and its surface (`'slide' | 'notes'`). The controller
  writes back through `withSurface`, so a notes edit lands in the frame's `notes` picture.
  `Selection`/`ConnectorSelection`/`autoEdit` all carry `surface`.
- **Active tracking.** An `IntersectionObserver` (root = the deck) reports the
  slide with the greatest visible area as `onActiveChange`; the controller uses
  it to move the navigator highlight. One observer per host, disconnected before
  each rebuild (`observers` WeakMap) so removed cards are not retained.
- **Scroll survives a full rebuild.** A coarse edit re-renders the whole deck;
  `paintDeck` captures and restores `scrollTop` so the view does not jump.
- **Surgical single-surface repaint (ADR 0016).** `repaintFrame(index, surface, frame, ctx)`
  re-measures and re-paints just one card in place (returns false if a full render
  replaced the deck under it), so a node-scoped content edit never rebuilds the deck.
  Re-measuring the whole picture is what keeps it correct when the edit reflows the node's
  box and shifts its `below=of` peers. A step scrub repaints both surfaces of the frame.
- **Selection is cheap.** `showSelection` toggles handle outlines across all
  cards without a re-render — a drag may be starting on the element. On the same
  repaint-free path, `setColumnEditors` mounts/clears the selected node's column grid
  affordance ([columnEditor.md](./columnEditor.md)) straight onto the live overlay.
- **Handle vs scroll.** Only `.sb-handle` sets `touch-action: none`; touching a
  slide's empty area still scrolls the deck.

- **Overlay preview (ADR 0018/0019).** `props.preview` (`{ frame, step } | null`) renders
  one frame at one build step (via `paintCanvas`'s `step`), driving BOTH its slide and its
  notes card at that step so the notes sync is visible while authoring; every other frame
  stays all-visible. `repaintFrame`'s ctx carries the same `step`.

Provisional: all slides render live; large decks will want off-screen slides
virtualised/snapshotted once the async DOM measurer lands (roadmap Track 0).
