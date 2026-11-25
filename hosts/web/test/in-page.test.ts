import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createFakeCore } from "../src/fixture/fake-core.ts";
import { packFiles, packParts, unpackFiles, unpackParts, type ProjectChange, type ProjectFile, type ProjectHost, type ProviderOutcome } from "../src/host/project-host.ts";
import { base16FromBytes, bytesFromBase16, requests, type Request, type SessionSuccess } from "../src/protocol/session.ts";
import { coreReads, fillBlobs, missingBlobs } from "../src/transport/in-page.ts";
import { createInPageTransport, nodeSizesPath } from "../src/transport/in-page.ts";
import type { SessionCore } from "../src/wasm/session-core.ts";

const encoder = new TextEncoder();
const decoder = new TextDecoder();
const bytes = (text: string): Uint8Array => encoder.encode(text);
const sample = new Uint8Array(readFileSync(new URL("../fixtures/plans/sample-deck.slideBlaster.md", import.meta.url)));
const tick = (): Promise<void> => new Promise((resolve) => setTimeout(resolve, 0));

/** A core that answers from a script: a valid view whose revision, saved mark and source it tracks. */
async function scriptedCore(): Promise<{ core: SessionCore; seen: Request[]; state: { revision: number; saved: number; source: Uint8Array; sizes: Uint8Array | null } }> {
  const template = await createFakeCore({ source: sample, figureDelayMs: null }).request(requests.workspaceSnapshot());
  assert.ok(template.ok);
  const state = { revision: 1, saved: 1, source: sample as Uint8Array, sizes: null as Uint8Array | null };
  const seen: Request[] = [];
  const reply = (kind: string, effects: unknown[] = []): Uint8Array =>
    bytes(JSON.stringify({ ...template, kind, effects, view: { ...template.view, revision: state.revision, saved: state.saved, source: { sourceBase16: base16FromBytes(state.source) } } }));
  const core: SessionCore = {
    async dispatch(frame) {
      const request = JSON.parse(decoder.decode(frame)) as Request;
      seen.push(request);
      switch (request.command) {
        case "open_project": {
          const files = request.files as { path: string; bytesBase16: string }[];
          state.source = bytesFromBase16(files.find((f) => f.path === request.entry)!.bytesBase16);
          return reply("opened", [{ kind: "block.render", ticket: 7, fingerprint: "fp", request: { slot: "block.render", kind: "tikz", input: { body: "x" } } }]);
        }
        case "command":
          return reply("save_requested", [{ kind: "storage", op: "write", path: "talk.slideBlaster.md", bytesBase16: base16FromBytes(state.source), revision: state.revision }]);
        case "storage_result": state.saved = request.revision as number; return reply("storage_acknowledged");
        case "replace_source": state.source = bytesFromBase16(request.sourceBase16 as string); state.revision += 1; return reply("source_replaced");
        case "apply_source_replace": state.source = bytes(decoder.decode(state.source) + "!"); state.revision += 1; return reply("source_replaced");
        case "provider_result": case "project_file": return reply("accepted");
        case "workspace_snapshot": return reply("snapshot");
        default: return bytes(JSON.stringify({ protocol: template.protocol, ok: false, kind: "error", error: { code: "unknown_command", message: "no" } }));
      }
    },
    async nodeSizes() { return state.sizes; },
  };
  return { core, seen, state };
}

function memoryHost(initial: Record<string, string>): ProjectHost & { files: Map<string, Uint8Array>; cache: Map<string, Uint8Array>; rendered: unknown[]; change(changes: ProjectChange[]): void; refuseWrites: boolean } {
  const files = new Map(Object.entries(initial).map(([path, text]) => [path, bytes(text)]));
  const cache = new Map<string, Uint8Array>();
  const listeners = new Set<(changes: readonly ProjectChange[]) => void>();
  const rendered: unknown[] = [];
  const host = {
    files, cache, rendered, refuseWrites: false,
    change(changes: ProjectChange[]) { for (const listener of listeners) listener(changes); },
    async list(): Promise<ProjectFile[]> { return [...files].map(([path, b]) => ({ path, bytes: b })); },
    async read(path: string) { return files.get(path) ?? null; },
    async write(path: string, expected: Uint8Array | null, next: Uint8Array) {
      const current = files.get(path) ?? null;
      const same = current === null ? expected === null : expected !== null && decoder.decode(current) === decoder.decode(expected);
      if (host.refuseWrites || !same) return { ok: false as const, reason: "conflict" };
      files.set(path, next);
      return { ok: true as const };
    },
    async writeCache(path: string, b: Uint8Array) { cache.set(path, b); },
    async renderBlock(request: Record<string, unknown>): Promise<ProviderOutcome> { rendered.push(request); return { artifact: { mime: "image/svg+xml", bytesBase16: "3c", width: 10, height: 5, provenance: "fake" } }; },
    onChange(listener: (changes: readonly ProjectChange[]) => void) { listeners.add(listener); return () => listeners.delete(listener); },
    async exportPdf() { return { ok: false, error: "not here" }; },
  };
  return host;
}

test("open lists the project, adds bundled themes the project lacks, and hides core-only effects", async () => {
  const { core, seen } = await scriptedCore();
  const host = memoryHost({ "talk.slideBlaster.md": "## A\n", "themes/fns/theme.css": "own" });
  const transport = createInPageTransport({ core, host, bundledThemes: async () => [{ path: "themes/fns/theme.css", bytes: bytes("bundled") }, { path: "themes/default/theme.css", bytes: bytes("d") }] });
  assert.equal(transport.state(), "open");
  const pushes: SessionSuccess[] = [];
  transport.onPush((push) => pushes.push(push));
  const opened = await transport.request(requests.openProject("talk.slideBlaster.md"));
  assert.ok(opened.ok);
  assert.deepEqual(opened.effects, [], "block.render is performed here, not handed to the page");
  assert.equal(seen[0]!.command, "image_refs", "the core is first told to name images rather than carry them");
  const sent = seen.find((r) => r.command === "open_project")!.files as { path: string; bytesBase16: string }[];
  assert.deepEqual(sent.map((f) => f.path).sort(), ["talk.slideBlaster.md", "themes/default/theme.css", "themes/fns/theme.css"]);
  assert.equal(decoder.decode(bytesFromBase16(sent.find((f) => f.path === "themes/fns/theme.css")!.bytesBase16)), "own", "the project's own theme wins");
  await tick(); await tick(); await tick();
  assert.equal(host.rendered.length, 1);
  const result = seen.find((r) => r.command === "provider_result")!;
  assert.deepEqual([result.ticket, result.fingerprint, (result.artifact as { mime: string }).mime], [7, "fp", "image/svg+xml"]);
  assert.deepEqual(pushes.map((p) => p.kind), ["view_updated"], "the figure's arrival is pushed");
});

test("save writes against what was last on disk and reports saved or save_failed", async () => {
  const { core, seen, state } = await scriptedCore();
  const host = memoryHost({ "talk.slideBlaster.md": "## A\n" });
  const transport = createInPageTransport({ core, host });
  await transport.request(requests.openProject("talk.slideBlaster.md"));
  await transport.request(requests.applySourceReplace(1, { start: 0, end: 0 }, new Uint8Array(), bytes("!")));
  const saved = await transport.request(requests.command("save"));
  assert.ok(saved.ok);
  assert.equal(saved.kind, "saved");
  assert.equal(saved.view.saved, saved.view.revision);
  assert.equal(decoder.decode(host.files.get("talk.slideBlaster.md")!), "## A\n!");
  assert.ok(seen.some((r) => r.command === "storage_result" && r.ok === true && r.revision === state.revision));

  // someone else changed the file: the compare-and-replace refuses, and the core is not told it saved
  host.files.set("talk.slideBlaster.md", bytes("theirs"));
  const before = seen.filter((r) => r.command === "storage_result").length;
  const refused = await transport.request(requests.command("save"));
  assert.ok(refused.ok);
  assert.equal(refused.kind, "save_failed");
  assert.equal(decoder.decode(host.files.get("talk.slideBlaster.md")!), "theirs");
  assert.equal(seen.filter((r) => r.command === "storage_result").length, before);
});

test("outside changes: other files reach the core, a clean deck reloads as saved, a dirty deck is left alone", async () => {
  const { core, seen, state } = await scriptedCore();
  const host = memoryHost({ "talk.slideBlaster.md": "## A\n" });
  const transport = createInPageTransport({ core, host });
  const pushes: SessionSuccess[] = [];
  transport.onPush((push) => pushes.push(push));
  await transport.request(requests.openProject("talk.slideBlaster.md"));
  await tick(); await tick(); await tick();
  pushes.length = 0;

  host.change([{ path: "figures/a.tikz", bytes: bytes("\\draw;") }, { path: ".slideblaster/cache/x", bytes: bytes("c") }, { path: ".git/HEAD", bytes: bytes("g") }]);
  await tick(); await tick();
  assert.deepEqual(seen.filter((r) => r.command === "project_file").map((r) => r.path), ["figures/a.tikz"], "caches and git are not project files");

  host.change([{ path: "talk.slideBlaster.md", bytes: bytes("## B\n") }]);
  await tick(); await tick(); await tick(); await tick();
  assert.equal(decoder.decode(state.source), "## B\n");
  assert.equal(state.saved, state.revision, "what the editor holds is what the disk holds");
  assert.equal(pushes.at(-1)!.view.saved, pushes.at(-1)!.view.revision);

  // our own save coming back from the watcher changes nothing
  const replaces = seen.filter((r) => r.command === "replace_source").length;
  host.change([{ path: "talk.slideBlaster.md", bytes: bytes("## B\n") }]);
  await tick(); await tick();
  assert.equal(seen.filter((r) => r.command === "replace_source").length, replaces);

  // unsaved edits are never overwritten by a change on disk
  await transport.request(requests.applySourceReplace(state.revision, { start: 0, end: 0 }, new Uint8Array(), bytes("!")));
  host.change([{ path: "talk.slideBlaster.md", bytes: bytes("## C\n") }]);
  await tick(); await tick();
  assert.equal(seen.filter((r) => r.command === "replace_source").length, replaces);
  assert.equal(decoder.decode(state.source), "## B\n!");
});

test("measured node sizes are kept in the project's cache when they change", async () => {
  const { core, state } = await scriptedCore();
  const host = memoryHost({ "talk.slideBlaster.md": "## A\n" });
  const transport = createInPageTransport({ core, host });
  await transport.request(requests.openProject("talk.slideBlaster.md"));
  await tick();
  assert.equal(host.cache.size, 0);
  state.sizes = bytes("{\"a\":[1,2]}");
  await transport.request(requests.workspaceSnapshot());
  await tick(); await tick();
  assert.equal(decoder.decode(host.cache.get(nodeSizesPath)!), "{\"a\":[1,2]}");
  host.cache.clear();
  await transport.request(requests.workspaceSnapshot());
  await tick(); await tick();
  assert.equal(host.cache.size, 0, "unchanged sizes are not written again");
});

test("library files the core asks for are supplied once, from what ships with the editor", async () => {
  const { core, seen } = await scriptedCore();
  const real = core.dispatch;
  let needs: string[] = ["shapes/flow.tikz", "shapes/absent.tikz", "../etc/passwd"];
  core.dispatch = async (frame) => {
    const response = JSON.parse(decoder.decode(await real(frame))) as { view?: { needs?: string[] } };
    if (response.view !== undefined) response.view.needs = needs;
    return bytes(JSON.stringify(response));
  };
  const asked: string[] = [];
  const transport = createInPageTransport({ core, host: memoryHost({ "talk.slideBlaster.md": "## A\n" }), library: async (path) => { asked.push(path); return path === "shapes/flow.tikz" ? bytes("\\tikzset{}") : null; } });
  await transport.request(requests.openProject("talk.slideBlaster.md"));
  await tick(); await tick(); await tick();
  assert.deepEqual(asked.sort(), ["shapes/absent.tikz", "shapes/flow.tikz"], "only library paths are looked up");
  assert.deepEqual(seen.filter((r) => r.command === "project_file").map((r) => r.path), ["shapes/flow.tikz"]);
  needs = ["shapes/absent.tikz"];
  await transport.request(requests.workspaceSnapshot());
  await tick(); await tick();
  assert.equal(asked.length, 2, "a file that is not shipped is not asked for again");
});

test("a closed transport refuses requests", async () => {
  const { core } = await scriptedCore();
  const transport = createInPageTransport({ core, host: memoryHost({ "talk.slideBlaster.md": "## A\n" }) });
  const states: string[] = [];
  transport.onState((s) => states.push(s));
  transport.close();
  assert.deepEqual(states, ["closed"]);
  await assert.rejects(transport.request(requests.workspaceSnapshot()));
});

test("packed parts and file listings round-trip and reject truncation", () => {
  const parts = [bytes("ab"), new Uint8Array(), bytes("xyz")];
  assert.deepEqual(unpackParts(packParts(parts)).map((p) => decoder.decode(p)), ["ab", "", "xyz"]);
  assert.deepEqual(unpackParts(packParts([])), []);
  assert.throws(() => unpackParts(packParts(parts).subarray(0, 9)));
  const files = [{ path: "a/b.md", bytes: bytes("one") }, { path: "c", bytes: new Uint8Array() }];
  assert.deepEqual(unpackFiles(packFiles(files)).map((f) => [f.path, decoder.decode(f.bytes)]), [["a/b.md", "one"], ["c", ""]]);
  assert.throws(() => unpackFiles(packParts([bytes("odd")])));
});

test("images named in a frame are asked for once and filled in wherever they are named", () => {
  const frame = { view: { items: [{ t: "image", bytesRef: "a.svg@3-1" }, { children: [{ t: "image", bytesRef: "b.png@9-2" }, { t: "image", bytesRef: "a.svg@3-1" }] }] } };
  const known = new Map<string, string>([["b.png@9-2", "00ff"]]);
  assert.deepEqual(missingBlobs(frame, known), ["a.svg@3-1"]);
  known.set("a.svg@3-1", "3c73");
  assert.deepEqual(missingBlobs(frame, known), []);
  fillBlobs(frame, known);
  const [first, group] = frame.view.items as unknown as [{ bytesBase16?: string }, { children: { bytesBase16?: string }[] }];
  assert.deepEqual([first.bytesBase16, group.children[0]!.bytesBase16, group.children[1]!.bytesBase16], ["3c73", "00ff", "3c73"]);
});

test("built documents and TeX's leftovers are not handed to the core", () => {
  for (const kept of ["talk.slideBlaster.md", "figures/arch.svg", "figures/a.tikz", "refs.bib", "themes/fns/theme.css", "src/config.tex", "img/photo.PNG"]) assert.equal(coreReads(kept), true, kept);
  for (const left of ["talk.pdf", ".build/presentation.log", "src/logo.eps", "presentation.aux", "a/b.synctex.gz", "build/x.svg", "notes.fdb_latexmk"]) assert.equal(coreReads(left), false, left);
});
