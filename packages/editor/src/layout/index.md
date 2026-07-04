# layout

The measure -> resolve pass (ADR 0014, engine track B): `resolveLayout` plus the
`Measurer` seam (`naiveMeasurer` now, the DOM measurer later) and the
`anchor`/`findPlaced` geometry helpers. Slide-space output, consumed by the render
track (SVG geometry + HTML content).
