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
  '.sb-slide{container-type:inline-size}',
  '.sb-content ul,.sb-content ol{margin:0;padding-left:1.4em}',
  '.sb-content .sb-math{font-style:italic}',
].join('\n')
