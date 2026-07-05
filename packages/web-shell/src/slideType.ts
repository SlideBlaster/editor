/**
 * Slide-proportional typography, in one place. Contract: see slideType.md.
 *
 * Type is sized in container-query units (`cqw`) against the slide box
 * (`.sb-slide` is the `inline-size` container), so a slide's text is a fixed
 * fraction of the slide at any pixel size — a thumbnail, the full canvas, the
 * offscreen measuring slide, and the exported page all render identical
 * proportions. That invariant is what lets the DOM measurer measure at one
 * reference width and have the result hold everywhere (domMeasurer.ts).
 *
 * Keyed on `.sb-slide` (not `.deck-slide`/`.thumb`) precisely so every context
 * that mounts a slide inherits the same metrics. The engine's `slideStylesheet()`
 * owns structure (positioning, the geometry layer); this owns the type scale.
 */
export const SLIDE_TYPE_CSS = [
  '.sb-slide{container-type:inline-size}',
  '.sb-content{font-size:2.6cqw;line-height:1.3;color:#1b1e28}',
  '.sb-node.sb-style-title{font-size:4.2cqw;font-weight:700;letter-spacing:-0.01em}',
  '.sb-content ul,.sb-content ol{margin:0;padding-left:1.4em}',
  '.sb-content .sb-math{font-style:italic}',
].join('\n')
