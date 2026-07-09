# live connector re-routing (liveConnectors.ts)

Keeps a node's attached arrows tracking it **during** a drag/resize, instead of leaving
them frozen until the commit re-render jumps them to their new endpoints (the "snappy"
feel). Used by the node-move gesture ([canvas.ts](./canvas.md) `wireHandle`) and both
resize gestures ([resizeHandles.ts](./resizeHandles.md)). The connector _reshape_ editor
([connectorEditor.ts](./connectorEditor.md)) already refreshes its own arrow live — this
covers the other side: the arrow moving because its **node** moved.

- **One entry point.** `rerouteConnectors(picture, layout, node, box, slideEl, overlay)`.
  `box` is the node's live on-screen `{ center, size }` (slide space, y-up) — the drag's
  resolved target for a move, the previewed box for a resize.
- **How.** Clone `layout` with just `node`'s box replaced by `box`, then reuse the engine's
  `connectorsOf(picture, patched)` — the single source of truth for arrow geometry, so a
  live re-route can never disagree with the committed render. Node-anchored endpoints
  (`(name)` / `(name.north)`) resolve against the new center/size and re-route for free.
- **In place, diffed.** Rewrites the `d` of the visible arrow (`.sb-arrow[data-arrow]` in
  the geometry layer) and the overlay hit-line (`[data-connector]`), and only when it
  actually changed — unattached arrows resolve identically and are skipped, so a move with
  no attached arrows costs one `connectorsOf` call and no DOM writes.
- **Commit vs preview.** The gesture still commits on pointerup, which re-renders and
  rebuilds the arrows for real — identical geometry, so no visible jump. The one path that
  ends **without** a commit (a resize `pointercancel`) re-routes back to the origin box.
