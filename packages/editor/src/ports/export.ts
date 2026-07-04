/**
 * Export port — durable artifacts from rendered slides.
 * Contract: see export.md.
 */

export interface RenderedSlide {
  /** Self-contained HTML for one slide (inline styles and SVG). */
  html: string
  /** Zero-based position in the deck. */
  index: number
}

export interface ExportPort {
  toPdf(slides: RenderedSlide[]): Promise<Blob>
  /** A single standalone presenter HTML file for the whole deck. */
  toStandaloneHtml(slides: RenderedSlide[]): Promise<string>
}
