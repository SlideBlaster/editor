/**
 * Slide-proportional typography, assembled from the active theme. Contract: see slideType.md.
 *
 * Type is sized in container-query units (`cqw`) against the slide box (`.sb-slide` is
 * the `inline-size` container), so a slide's text is a fixed fraction of the slide at any
 * pixel size — a thumbnail, the full canvas, the offscreen measuring slide, and the
 * exported page all render identical proportions. That invariant is what lets the DOM
 * measurer measure at one reference width and have the result hold everywhere
 * (domMeasurer.ts).
 *
 * The type scale + per-role looks now come from the **theme** (`themeStylesheet`, ADR
 * 0017); `SLIDE_THEME_CSS` is that output for the active theme (the built-in default
 * until the theme loader lands). `SLIDE_TYPE_CSS` keeps only the structural, non-theme
 * rules — the `container-type` declaration, list indentation, math italics. Both are
 * keyed on `.sb-slide`/`.sb-content` and injected together into every mount context.
 */
import { defaultTheme, themeStylesheet } from '@slideblaster/editor'

/** The active theme's style layer as CSS (palette + type scale + per-role looks). */
export const SLIDE_THEME_CSS = themeStylesheet(defaultTheme)

/** Structural, non-theme slide rules shared by every mount context. */
export const SLIDE_TYPE_CSS = [
  // A slide must render identically wherever it mounts, so it can't inherit text
  // properties from its host. `text-align:left` pins the baseline: without it a slide in a
  // `<button>` thumbnail inherits the button's `text-align:center` and every line centres,
  // drifting off the left-aligned canvas. Per-role `align` in the theme still overrides.
  '.sb-slide{container-type:inline-size;text-align:left}',
  // Lists: markers are `inside` (in the box model) with a hanging indent, NOT the default
  // `outside`. Outside markers are painted outside layout, and Chromium mispositions them
  // to the far left under a CSS `transform:scale()` — which the thumbnails use — so an
  // outside bullet drifts off the canvas in the preview. An inside marker + text-indent
  // gives the same hanging bullet but scales exactly with the slide, canvas and thumbnail.
  '.sb-content ul,.sb-content ol{margin:0;padding-left:1.4em;list-style-position:inside}',
  '.sb-content li{padding-left:1.4em;text-indent:-1.4em}',
  '.sb-content .sb-math{font-style:italic}',
].join('\n')
