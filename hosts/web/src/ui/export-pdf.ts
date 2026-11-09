/**
 * "Export PDF": ask `sb serve` (`POST /export/pdf`) to build the PDF of the open deck. The server
 * prints the offline page with headless Chrome and writes `<deck>.pdf` next to the deck; this
 * module only builds the request and words the result. Pure apart from the injected `fetch`.
 */
export interface PdfExportResult {
  readonly ok: boolean;
  /** Absolute path of the written PDF. */
  readonly path?: string;
  readonly name?: string;
  readonly error?: string;
  /** Slide items whose content runs out of their box or off the slide. */
  readonly warnings?: readonly string[];
}

export type Fetcher = (url: string, init: { method: string }) => Promise<{ json(): Promise<unknown> }>;

export function exportPdfUrl(origin: string, entry: string, steps: boolean): string {
  return `${origin}/export/pdf?entry=${encodeURIComponent(entry)}${steps ? "&steps=1" : ""}`;
}

export async function exportPdf(fetcher: Fetcher, origin: string, entry: string, steps: boolean): Promise<PdfExportResult> {
  try {
    const response = await fetcher(exportPdfUrl(origin, entry, steps), { method: "POST" });
    const body = (await response.json()) as Partial<PdfExportResult> | null;
    if (body !== null && typeof body === "object" && body.ok === true && typeof body.path === "string") {
      const warnings = Array.isArray(body.warnings) ? body.warnings.filter((w): w is string => typeof w === "string") : [];
      return { ok: true, path: body.path, name: typeof body.name === "string" ? body.name : undefined, warnings };
    }
    return { ok: false, error: typeof body?.error === "string" ? body.error : "the server refused the export" };
  } catch (error) {
    return { ok: false, error: `could not reach sb serve: ${error instanceof Error ? error.message : String(error)}` };
  }
}

export function pdfStatus(result: PdfExportResult): string {
  if (!result.ok) return `PDF export failed: ${result.error}`;
  const warnings = result.warnings ?? [];
  if (warnings.length === 0) return `PDF written: ${result.path}`;
  return `PDF written: ${result.path}, but ${warnings.length} out of bounds: ${warnings.join("; ")}`;
}
