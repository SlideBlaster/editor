# shapesPanel — the docked shapes library rail

`renderShapesPanel(host, { onInsert })` renders the `shapes/catalog` into the right-rail
aside (`#shapes-panel`): a title, a search box, and a scrollable list. With no search, the
list is one collapsible `<details>` per **family** (`shapeFamilies()` — ~17 headings, not the
~80 raw stencil sub-sets); with a query, it's a flat grid of matches. Re-render is idempotent
(replaces prior content).

Each cell is a `draggable` button showing the shape's thumbnail over its label. The
thumbnail is drawn by the engine's `shapeGeometrySvg` — the same function the canvas draws a
node box with — so the preview always matches what dropping the shape produces.

## Contract

- `onInsert(shapeId)` is called on a cell CLICK (the controller drops the shape at the
  active slide's centre). Dragging a cell sets the shape id on the drag `dataTransfer` under
  `SHAPE_DRAG_MIME`; the deck's drop handler (in `createApp`) reads it and inserts at the
  cursor point. This module owns the drag source, not the drop.
- **Scales to thousands.** A family's grid is rendered LAZILY — its thumbnails are built the
  first time it opens (General/Flowchart start open; the big stencil families start closed), so
  mounting never draws 2000+ SVGs at once. Search is debounced and its flat grid is capped
  (300, with a "showing N of M" note) so a broad query stays responsive.
- Search filters shapes by label/keywords via `shapeMatches`; an empty result shows a note.
- Pure presentation over the catalogue: it knows nothing about the document, the frame, or
  how a shape becomes TikZ — only the controller's `onInsert` and the drag payload.
- **Attribution footer.** A pinned credit ("Stencils from draw.io · CC BY 4.0", both linked)
  sits below the list — the stencil library is derived from draw.io under CC BY 4.0, which
  requires a visible credit. See `THIRD_PARTY_NOTICES.md`.

See `shapes/catalog.md` (the data), the engine `render/shape.md` (the shared geometry), and
`createApp` (mounts the panel and handles canvas drops).
