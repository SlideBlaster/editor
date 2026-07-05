/**
 * Browser export adapter. Contract: see export.md.
 *
 * Turns already-rendered slides (`RenderedSlide[]` from the engine renderer) into a
 * single self-contained document that is BOTH an on-screen presenter (scroll / arrow
 * keys, one slide per view) AND a print-to-PDF source (each slide one 16:9 page). The
 * slides carry no external assets, so the document inlines the engine stylesheet and
 * the shared slide type scale and is fully offline.
 *
 * PDF is the browser's own print pipeline (`window.print()` in a hidden iframe), which
 * renders the exact same DOM+CSS — the highest-fidelity path and the one export.md
 * commits to for the browser. It cannot hand back a `Blob`, so the port's
 * `toPdf(): Promise<Blob>` stays the native/managed adapters' job; the browser offers
 * `toStandaloneHtml` (port-conformant) plus `downloadDeckHtml` and `printDeck`.
 */
import { slideStylesheet, type RenderedSlide } from '@slideblaster/editor'
import { SLIDE_TYPE_CSS } from './slideType'
import { KATEX_CSS } from './katexInlineCss'

/** Standard 16:9 slide page (PowerPoint/Beamer widescreen), used for the print @page. */
const PAGE = { w: '13.333in', h: '7.5in' }

/** A self-contained deck document: on-screen presenter + print-to-PDF pages. */
export function toStandaloneHtml(
  slides: RenderedSlide[],
  opts: { title?: string } = {},
): Promise<string> {
  return Promise.resolve(buildDeckDocument(slides, opts.title ?? 'Slides'))
}

/** Download the standalone deck as an .html file. */
export async function downloadDeckHtml(
  slides: RenderedSlide[],
  opts: { title?: string; filename?: string } = {},
): Promise<void> {
  const html = await toStandaloneHtml(slides, opts)
  const blob = new Blob([html], { type: 'text/html' })
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = opts.filename ?? `${slugify(opts.title ?? 'slides')}.html`
  a.click()
  URL.revokeObjectURL(url)
}

/**
 * Open the browser print dialog on the deck (each slide one page) — "Save as PDF".
 * Renders into a hidden iframe so the app UI is never navigated away from.
 */
export async function printDeck(
  slides: RenderedSlide[],
  opts: { title?: string } = {},
): Promise<void> {
  const html = await toStandaloneHtml(slides, opts)
  const iframe = document.createElement('iframe')
  iframe.setAttribute('aria-hidden', 'true')
  iframe.style.cssText =
    'position:fixed;right:0;bottom:0;width:0;height:0;border:0;visibility:hidden'
  document.body.append(iframe)

  await new Promise<void>((resolve) => {
    iframe.addEventListener('load', () => resolve(), { once: true })
    const doc = iframe.contentDocument!
    doc.open()
    doc.write(html)
    doc.close()
  })

  const win = iframe.contentWindow
  if (!win) {
    iframe.remove()
    return
  }
  // Remove the iframe once printing is done (or dismissed); afterprint is not
  // universally reliable, so a fallback timer also cleans up.
  const cleanup = (): void => iframe.remove()
  win.addEventListener('afterprint', cleanup, { once: true })
  setTimeout(cleanup, 60_000)
  win.focus()
  win.print()
}

/** Assemble the full HTML document. Slide HTML is trusted engine output. */
function buildDeckDocument(slides: RenderedSlide[], title: string): string {
  const ordered = [...slides].sort((a, b) => a.index - b.index)
  const pages = ordered.map((s) => `<section class="export-slide">${s.html}</section>`).join('\n')
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>${escapeHtml(title)}</title>
<style>
${DOCUMENT_CSS}
${slideStylesheet()}
${SLIDE_TYPE_CSS}
${KATEX_CSS}
</style>
</head>
<body>
<div class="export-deck">
${pages}
</div>
<script>${PRESENTER_JS}</script>
</body>
</html>`
}

/** Screen presenter chrome + print page rules. Slide type/structure come from the engine. */
const DOCUMENT_CSS = [
  '*{box-sizing:border-box;margin:0}',
  'html,body{height:100%}',
  'html{scroll-snap-type:y mandatory;scroll-behavior:smooth}',
  'body{background:#0e0f13;font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif}',
  '.export-slide{min-height:100vh;display:flex;align-items:center;justify-content:center;padding:4vh 4vw;scroll-snap-align:start}',
  // Fit the 16:9 slide to the viewport (letterboxed), pick the limiting dimension.
  '.export-slide .sb-slide{width:min(92vw, calc(92vh * 16 / 9));box-shadow:0 12px 48px rgba(0,0,0,0.55)}',
  '@media print{',
  `  @page{size:${PAGE.w} ${PAGE.h};margin:0}`,
  '  html{scroll-snap-type:none}',
  '  body{background:#fff}',
  `  .export-slide{display:block;min-height:auto;width:${PAGE.w};height:${PAGE.h};padding:0;break-after:page;page-break-after:always}`,
  '  .export-slide:last-child{break-after:auto;page-break-after:auto}',
  `  .export-slide .sb-slide{width:${PAGE.w};height:${PAGE.h};box-shadow:none;border:0;border-radius:0}`,
  '}',
].join('\n')

/** Arrow/space/PageUp-Down step through slides on screen (ignored when printing). */
const PRESENTER_JS = `
const slides = [...document.querySelectorAll('.export-slide')];
let i = 0;
function go(n){ i = Math.max(0, Math.min(slides.length - 1, n)); slides[i].scrollIntoView(); }
addEventListener('keydown', (e) => {
  if (e.key === 'ArrowRight' || e.key === 'ArrowDown' || e.key === 'PageDown' || e.key === ' ') { e.preventDefault(); go(i + 1); }
  else if (e.key === 'ArrowLeft' || e.key === 'ArrowUp' || e.key === 'PageUp') { e.preventDefault(); go(i - 1); }
  else if (e.key === 'Home') { e.preventDefault(); go(0); }
  else if (e.key === 'End') { e.preventDefault(); go(slides.length - 1); }
});
`.trim()

function slugify(text: string): string {
  return (
    text
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, '-')
      .replace(/^-+|-+$/g, '') || 'slides'
  )
}

function escapeHtml(text: string): string {
  return text
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
}
