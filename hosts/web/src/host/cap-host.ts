/**
 * `ProjectHost` over `sb serve`'s `/cap` socket: the core runs in the page, and the server is used
 * only as the project's files and figure compiler. This is the in-page core in a plain browser
 * tab (`?core=page`), for development and for tests that drive a real browser.
 */
import { relayBlockRender, type CapClient } from "../cap/client.ts";
import { exportPdf } from "../ui/export-pdf.ts";
import type { ProjectChange, ProjectHost, ProviderOutcome } from "./project-host.ts";

export function createCapProjectHost(cap: CapClient, origin: string): ProjectHost {
  const read = async (path: string): Promise<Uint8Array | null> => {
    try { return await cap.read(path); } catch { return null; }
  };
  let watching = false;
  return {
    async list() {
      await cap.ready();
      const entries = await cap.listProject("", true);
      const files = await Promise.all(entries.filter((e) => e.kind === "file" && (e.size ?? 0) <= 16777216).map(async (e) => ({ path: e.path, bytes: await read(e.path) })));
      return files.flatMap((f) => (f.bytes === null ? [] : [{ path: f.path, bytes: f.bytes }]));
    },
    read,
    async write(path, expected, bytes) {
      try { await cap.save(path, expected, bytes); return { ok: true }; }
      catch (failure) { return { ok: false, reason: failure instanceof Error ? failure.message : "the write failed" }; }
    },
    async writeCache() { /* the cache folder is not writable through /cap; `sb serve` keeps its own */ },
    async renderBlock(request) {
      return (await relayBlockRender({ ticket: 0, fingerprint: "", request }, cap)) as unknown as ProviderOutcome;
    },
    onChange(listener) {
      const stop = cap.onEvent((event) => {
        if (event.event !== "watch") return;
        void Promise.all(event.changes.map(async (c): Promise<ProjectChange> => ({ path: c.path, bytes: c.change === "deleted" ? null : await read(c.path) }))).then(listener);
      });
      if (!watching) { watching = true; void cap.ready().then(() => cap.subscribeWatch()).catch(() => { /* no live reload */ }); }
      return stop;
    },
    exportPdf: (entry, steps) => exportPdf((url, init) => fetch(url, init), origin, entry, steps),
  };
}
