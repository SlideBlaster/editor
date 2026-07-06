/**
 * KaTeX math renderer. Contract: see math.md.
 *
 * Fills the engine's `renderMath` seam so `$…$` / `$$…$$` typeset instead of showing
 * their source. `tableCompiler.ts` composes this into the one shared `renderOptions`
 * passed everywhere a slide is rendered — the canvas, the DOM measurer, the navigator
 * thumbnails, and the export — so measurement and every rendered surface agree. The
 * matching stylesheet is `katexInlineCss.ts` (self-contained, fonts embedded), injected
 * once document-wide.
 */
import katex from 'katex'

/** Render inline/display math. `throwOnError:false` shows bad input in place (never throws). */
export function renderMath(source: string, display: boolean): string {
  return katex.renderToString(source, { displayMode: display, throwOnError: false })
}
