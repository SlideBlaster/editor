# web-shell entry (main.ts)

The reactive render + edit controller. Runs the editor engine unchanged in the
browser and keeps a **two-way** loop between the source text and the slide, both
sharing one source of truth (the `.slideBlaster.md` text, A1).

```
text -> render (W2):   code pane -> fromMarkdown -> resolveLayout -> renderSlide
canvas -> text (W4):   gesture   -> E1 edit op   -> toMarkdown    -> code pane
```

- **Edit actions.** `CanvasActions` map a canvas gesture to an engine edit op on the
  current frame's picture: `move -> moveNodeTo`, `create -> createNode`,
  `remove -> deleteNode`. Each applies to the last good parsed document, swaps the
  one edited frame (`withFrame`), re-serializes with `toMarkdown`, pushes the new
  source into the code pane (`setValue`), and re-renders.
- **Selection is cheap.** `select` only toggles handle classes; it must not
  re-render, or it would destroy the element a drag started on.
- **Delete key** removes the selection, except while typing in the code pane.
- **Canvas edits canonicalize.** `toMarkdown` re-emits the whole document in canonical
  form, so a canvas edit normalizes source formatting document-wide (fine for the
  canonical sample; surgical per-frame splicing is a later refinement).
- **Tolerant parse.** A malformed manual edit shows an error banner and keeps the last
  good render. **Measurer** is `naiveMeasurer` until W3's DOM measurer.
- **Styling seam.** `slideStylesheet()` supplies the base layered-DOM rules; `app.css`
  layers the workspace chrome, the interaction overlay, and slide-proportional type.
