# web-shell entry (main.ts)

The W1 mount: runs the editor engine unchanged in the browser and paints its output
into the page. This is the "visible mount" the M2 milestone builds on (roadmap).

Pipeline, per frame:

```
source .slideBlaster.md  (imported ?raw)
  -> fromMarkdown           document container round-trip
  -> frame.picture          a slide is a TikZ picture (ADR 0004)
  -> resolveLayout(_, naiveMeasurer)   measure -> resolve (B1)
  -> renderSlide            layered SVG geometry + HTML content (ADR 0014, B3)
  -> element.innerHTML
```

- **No edit yet.** W1 is read-only render: a main stage plus a filmstrip of
  live-rendered thumbnails, click to select a frame. The code pane (W2) and canvas
  editing (W4+, which need engine edit ops) come later.
- **Measurer.** Uses `naiveMeasurer`; text metrics are approximate until W3 swaps in
  a DOM-measurement adapter (the Track-0 async-measurement risk).
- **Styling seam.** `slideStylesheet()` (engine) supplies the base layered-DOM rules;
  `app.css` layers the workspace chrome and slide-proportional font sizing on top.
