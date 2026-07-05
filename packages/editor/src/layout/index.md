# layout

The measure -> resolve pass (ADR 0014, engine track B): `resolveLayout` (sync) and
`resolveLayoutAsync` (async) plus the `Measurer` / `BatchMeasurer` seam
(`naiveMeasurer` now, the DOM measurer behind the async twin) and the
`anchor`/`findPlaced` geometry helpers. Slide-space output, consumed by the render
track (SVG geometry + HTML content).
