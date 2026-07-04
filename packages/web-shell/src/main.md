# web-shell entry (main.ts)

The reactive render controller: runs the editor engine unchanged in the browser and
keeps a live edit loop between the source text and the rendered slide.

Pipeline, per frame:

```
code pane text            (the .slideBlaster.md source of truth, A1)
  -> fromMarkdown           document container round-trip
  -> frame.picture          a slide is a TikZ picture (ADR 0004)
  -> resolveLayout(_, naiveMeasurer)   measure -> resolve (B1)
  -> renderSlide            layered SVG geometry + HTML content (ADR 0014, B3)
  -> stage + filmstrip
```

- **W2 — live round-trip.** A two-pane workspace: an editable code pane (source of
  truth) beside the rendered stage, plus a filmstrip of live thumbnails. Every edit
  re-parses and re-renders. Frame selection is click-through on the filmstrip.
- **Tolerant parse.** A malformed edit shows an error banner and keeps the last good
  render rather than blanking the stage.
- **Source seam, not model state.** The controller owns `source -> fromMarkdown ->
  render`; the code pane is one editable view. Canvas edits (W4+, via engine edit
  ops) will mutate the model and push new source through the same seam
  (`CodePane.setValue`).
- **Measurer.** `naiveMeasurer`; text metrics are approximate until W3 swaps in a
  DOM-measurement adapter (the Track-0 async-measurement risk).
- **Styling seam.** `slideStylesheet()` (engine) supplies the base layered-DOM rules;
  `app.css` layers the workspace chrome and slide-proportional font sizing on top.
