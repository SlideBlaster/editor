/**
 * KaTeX math renderer. Contract: see math.md.
 *
 * Fills the engine's `renderMath` seam (RenderOptions) so `$…$` / `$$…$$` typeset
 * instead of showing their source. One shared `mathOptions` is passed everywhere a
 * slide is rendered — the canvas, the DOM measurer, the navigator thumbnails, and the
 * export — so measurement and every rendered surface agree. The matching stylesheet is
 * `katexInlineCss.ts` (self-contained, fonts embedded), injected once document-wide.
 */
import katex from 'katex'
import type { RenderOptions } from '@slideblaster/editor'

/** Render inline/display math. `throwOnError:false` shows bad input in place (never throws). */
function renderMath(source: string, display: boolean): string {
  return katex.renderToString(source, { displayMode: display, throwOnError: false })
}

/** RenderOptions wiring KaTeX into the engine — share this across all render call sites. */
export const mathOptions: RenderOptions = { renderMath }
