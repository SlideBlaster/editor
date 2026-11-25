/**
 * `ProjectHost` of the desktop app: the project is a real folder, reached through the shell's own
 * commands. There is no server and no socket: the page is the app's bundled page, the core runs in
 * it, and the shell only reads, writes and watches files and runs the figure and PDF tools.
 */
import type { PdfExportResult } from "../ui/export-pdf.ts";
import { absentOutcome, packParts, unpackFiles, unpackParts, type ProjectChange, type ProjectHost, type ProviderOutcome } from "./project-host.ts";

/** The part of `window.__TAURI__` this host uses. */
export interface ShellApi {
  invoke(command: string, args?: unknown): Promise<unknown>;
  listen(event: string, handler: (event: { payload: unknown }) => void): Promise<() => void>;
}

const encoder = new TextEncoder();
const bytesOf = (value: unknown): Uint8Array => (value instanceof ArrayBuffer ? new Uint8Array(value) : value instanceof Uint8Array ? value : Uint8Array.from(value as number[]));

export function createShellProjectHost(shell: ShellApi): ProjectHost {
  const read = async (path: string): Promise<Uint8Array | null> => {
    const parts = unpackParts(bytesOf(await shell.invoke("project_read", { path })));
    return parts[0] ?? null;
  };
  return {
    async list() { return unpackFiles(bytesOf(await shell.invoke("project_list"))); },
    read,
    async write(path, expected, bytes) {
      const body = packParts([encoder.encode(path), Uint8Array.of(expected === null ? 0 : 1), expected ?? new Uint8Array(), bytes]);
      try { await shell.invoke("project_write", body); return { ok: true }; }
      catch (failure) { return { ok: false, reason: String(failure) }; }
    },
    async writeCache(path, bytes) { await shell.invoke("project_cache_write", packParts([encoder.encode(path), bytes])); },
    async renderBlock(request) {
      try { return JSON.parse(String(await shell.invoke("render_block", { request: JSON.stringify(request) }))) as ProviderOutcome; }
      catch (failure) { return absentOutcome("provider_absent", String(failure)); }
    },
    onChange(listener) {
      let stop: (() => void) | null = null;
      let stopped = false;
      void shell.listen("sb-project-changed", (event) => {
        const paths = (event.payload as { paths?: unknown }).paths;
        if (!Array.isArray(paths)) return;
        void Promise.all(paths.filter((p): p is string => typeof p === "string").map(async (path): Promise<ProjectChange> => ({ path, bytes: await read(path).catch(() => null) }))).then(listener);
      }).then((unlisten) => { if (stopped) unlisten(); else stop = unlisten; });
      return () => { stopped = true; stop?.(); };
    },
    async exportPdf(entry, steps): Promise<PdfExportResult> {
      try { return (await shell.invoke("export_pdf", { entry, steps })) as PdfExportResult; }
      catch (failure) { return { ok: false, error: String(failure) }; }
    },
  };
}
