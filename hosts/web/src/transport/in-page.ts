/**
 * `SessionTransport` over the core in the page (milestone W-web): no server, no socket. The core
 * only computes; this module performs what `sb serve`'s driver performs natively
 * (`SlideBlaster.Product.Runtime.Driver`): it lists the project on open, writes saves with a
 * compare-and-replace, compiles figures through the host and reports them back, and feeds file
 * changes from outside to the core. It holds no deck knowledge: every decision is the core's.
 */
import type { ProjectChange, ProjectFile, ProjectHost, ProviderOutcome } from "../host/project-host.ts";
import { failedOutcome } from "../host/project-host.ts";
import { bytesFromBase16, decodeSessionResponse, requests, type Effect, type Request, type SessionResponse, type SessionSuccess } from "../protocol/session.ts";
import type { SessionCore } from "../wasm/session-core.ts";
import type { ConnectionState, SessionTransport } from "./transport.ts";
import { TransportError } from "./transport.ts";

export const nodeSizesPath = ".slideblaster/cache/node-sizes.json";

export interface InPageOptions {
  readonly core: SessionCore;
  readonly host: ProjectHost;
  /** Themes shipped with the editor, offered as `themes/<name>/...` unless the project has its own. */
  readonly bundledThemes?: () => Promise<readonly ProjectFile[]>;
  /** A library file shipped with the editor (`shapes/<family>.tikz`), or `null`. */
  readonly library?: (path: string) => Promise<Uint8Array | null>;
}

const encoder = new TextEncoder();
const decoder = new TextDecoder();

type Fields = Record<string, unknown>;
const fields = (effect: Effect): Fields => effect as unknown as Fields;
/** Effects the page acts on; `storage` and `block.render` are performed here. */
const uiVisible = (effect: Effect): boolean => effect.kind !== "block.render" && effect.kind !== "storage" && effect.kind !== "file.write";

const sameBytes = (a: Uint8Array, b: Uint8Array): boolean => {
  if (a.length !== b.length) return false;
  for (let index = 0; index < a.length; index += 1) if (a[index] !== b[index]) return false;
  return true;
};

/** Whether a project file is worth handing to the core: not a built document, a TeX by-product or something in a build folder. */
export function coreReads(path: string): boolean {
  if (/(^|\/)(\.build|build|out|dist|node_modules)\//.test(path)) return false;
  return !/\.(pdf|eps|ps|dvi|log|aux|bcf|fls|fdb_latexmk|synctex\.gz|synctex|out|nav|snm|toc|vrb|blg|run\.xml|xdv|zip|gz|tar|mp4|mov|pptx|key|docx|xlsx)$/i.test(path);
}

/** Walk a decoded frame: every object that names its bytes (`bytesRef`). */
function eachBlobUser(value: unknown, visit: (holder: { bytesRef: string; bytesBase16?: string }) => void): void {
  if (Array.isArray(value)) { for (const item of value) eachBlobUser(item, visit); return; }
  if (typeof value !== "object" || value === null) return;
  const holder = value as { bytesRef?: unknown };
  if (typeof holder.bytesRef === "string") visit(holder as { bytesRef: string });
  for (const key in value) { const inner = (value as Record<string, unknown>)[key]; if (typeof inner === "object" && inner !== null) eachBlobUser(inner, visit); }
}

/** The names in a frame whose bytes are not known yet. */
export function missingBlobs(frame: unknown, known: ReadonlyMap<string, string>): string[] {
  const wanted = new Set<string>();
  eachBlobUser(frame, (holder) => { if (!known.has(holder.bytesRef)) wanted.add(holder.bytesRef); });
  return [...wanted];
}

/** Give every object that names its bytes the bytes themselves, so the rest of the page reads a plan as it always did. */
export function fillBlobs(frame: unknown, known: ReadonlyMap<string, string>): void {
  eachBlobUser(frame, (holder) => { const bytes = known.get(holder.bytesRef); if (bytes !== undefined) holder.bytesBase16 = bytes; });
}

export function createInPageTransport(options: InPageOptions): SessionTransport {
  const { core, host } = options;
  const pushListeners = new Set<(push: SessionSuccess) => void>();
  const stateListeners = new Set<(state: ConnectionState) => void>();
  let state: ConnectionState = "open";
  let entry = "";
  /** The deck's bytes as last read from or written to disk. */
  let onDisk: Uint8Array | null = null;
  let latest: SessionSuccess | null = null;
  let keptSizes: Uint8Array | null = null;
  /** The core answers one frame at a time; everything that reaches it queues here. */
  let tail: Promise<unknown> = Promise.resolve();
  /** Image bytes by the name the core gives them; a changed file gets a new name. */
  const blobs = new Map<string, string>();
  let refsAsked = false;

  function call(request: Request): Promise<SessionResponse> {
    const run = tail.then(async () => {
      if (state === "closed") throw new TransportError("transport closed");
      const dispatch = async (one: Request): Promise<unknown> => JSON.parse(decoder.decode(await core.dispatch(encoder.encode(JSON.stringify(one)))));
      if (!refsAsked) {
        // images are named in plans and fetched once, instead of travelling in every plan
        refsAsked = true;
        await dispatch(requests.imageRefs(true)).catch(() => undefined);
      }
      const raw = await dispatch(request);
      const missing = missingBlobs(raw, blobs);
      if (missing.length > 0) {
        const got = (await dispatch(requests.resources(missing))) as { effects?: { kind?: string; ref?: string; bytesBase16?: string }[] };
        for (const effect of got.effects ?? []) if (effect.kind === "resource" && typeof effect.ref === "string" && typeof effect.bytesBase16 === "string") blobs.set(effect.ref, effect.bytesBase16);
      }
      fillBlobs(raw, blobs);
      const response = decodeSessionResponse(raw);
      if (response.ok) latest = response;
      return response;
    });
    tail = run.catch(() => undefined);
    return run;
  }

  /** Library files the core asked for; each is looked up once (a missing one stays missing). */
  const supplied = new Set<string>();
  function supplyNeeds(response: SessionSuccess): void {
    if (options.library === undefined) return;
    for (const path of response.view.needs ?? []) {
      if (supplied.has(path) || !/^shapes\/[A-Za-z0-9_-]+\.tikz$/.test(path)) continue;
      supplied.add(path);
      void options.library(path).catch(() => null).then((bytes) => { if (bytes !== null) return pushWith(requests.projectFile(path, bytes)); });
    }
  }

  function emit(push: SessionSuccess): void {
    for (const listener of [...pushListeners]) listener(push);
  }

  /** Run a request the page did not ask for and show its result. */
  async function pushWith(request: Request): Promise<void> {
    let response: SessionResponse;
    try { response = await call(request); } catch (failure) { console.warn(`SlideBlaster core: ${request.command} failed`, failure); return; }
    // A stale ticket (the deck moved on) is ordinary; anything else is worth seeing.
    if (!response.ok) { if (response.error.code !== "stale_ticket") console.warn(`SlideBlaster core refused ${request.command}: ${response.error.code}: ${response.error.message}`); return; }
    // the view first: a render it asks for must not announce itself before it
    emit({ ...response, kind: "view_updated", effects: response.effects.filter(uiVisible) });
    spawnRenders(response.effects);
    supplyNeeds(response);
    void keepNodeSizes();
  }

  function spawnRenders(effects: readonly Effect[]): void {
    for (const effect of effects) {
      if (effect.kind !== "block.render") continue;
      const { ticket, fingerprint, request } = fields(effect);
      if (typeof ticket !== "number" || typeof fingerprint !== "string" || typeof request !== "object" || request === null) continue;
      void host.renderBlock(request as Fields)
        .catch((): ProviderOutcome => failedOutcome("provider_error", "the provider failed unexpectedly"))
        .then((outcome) => pushWith(requests.providerResult(ticket, fingerprint, outcome as unknown as Fields)));
    }
  }

  async function keepNodeSizes(): Promise<void> {
    try {
      const sizes = await core.nodeSizes();
      if (sizes === null || (keptSizes !== null && sameBytes(sizes, keptSizes))) return;
      await host.writeCache(nodeSizesPath, sizes);
      keptSizes = sizes;
    } catch { /* the cache is a convenience for `sb build`; the editor works without it */ }
  }

  async function withProject(request: Request): Promise<Request> {
    if (request.command === "open_source") { entry = "deck.slideBlaster.md"; onDisk = null; return request; }
    if (request.command !== "open_project" || typeof request.entry !== "string") return request;
    entry = request.entry;
    if (Array.isArray(request.files)) {
      const given = (request.files as { path?: unknown; bytesBase16?: unknown }[]).find((file) => file.path === entry);
      onDisk = typeof given?.bytesBase16 === "string" ? bytesFromBase16(given.bytesBase16) : null;
      return request;
    }
    // what the core cannot use stays out: built PDFs, TeX's own leftovers, a build folder
    const project = (await host.list()).filter((file) => file.path === entry || coreReads(file.path));
    const have = new Set(project.map((file) => file.path));
    const bundled = options.bundledThemes === undefined ? [] : await options.bundledThemes().catch(() => []);
    const files = [...project, ...bundled.filter((file) => !have.has(file.path))];
    onDisk = files.find((file) => file.path === entry)?.bytes ?? null;
    keptSizes = files.find((file) => file.path === nodeSizesPath)?.bytes ?? null;
    return requests.openProject(entry, files);
  }

  /** Perform the first `storage` effect and tell the core how it went. */
  async function performStorage(response: SessionSuccess): Promise<SessionSuccess> {
    // a figure file the core changed is written as it is
    for (const effect of response.effects.map(fields)) {
      if (effect.kind !== "file.write" || typeof effect.path !== "string" || typeof effect.bytesBase16 !== "string" || typeof effect.expectedBase16 !== "string") continue;
      await host.write(effect.path, bytesFromBase16(effect.expectedBase16), bytesFromBase16(effect.bytesBase16)).catch(() => undefined);
    }
    const storage = response.effects.map(fields).find((effect) => effect.kind === "storage");
    if (storage === undefined) return response;
    const { path, bytesBase16, revision } = storage;
    if (typeof path !== "string" || typeof bytesBase16 !== "string" || typeof revision !== "number") return { ...response, kind: "save_failed" };
    const bytes = bytesFromBase16(bytesBase16);
    const written = await host.write(path, onDisk, bytes).catch((): { ok: false; reason: string } => ({ ok: false, reason: "the write failed" }));
    if (!written.ok) return { ...response, kind: "save_failed" };
    onDisk = bytes;
    const recorded = await call(requests.storageResult(path, revision, true));
    return recorded.ok ? { ...recorded, kind: "saved", effects: response.effects } : { ...response, kind: "save_failed" };
  }

  async function fileChanged(change: ProjectChange): Promise<void> {
    if (change.path === nodeSizesPath || change.path.startsWith(".slideblaster/") || change.path.startsWith(".git/")) return;
    if (change.path !== entry) return pushWith(requests.projectFile(change.path, change.bytes));
    const view = latest?.view;
    if (change.bytes === null || view === undefined || view.source === undefined) return;
    if (onDisk !== null && sameBytes(change.bytes, onDisk)) return; // our own save coming back
    const current = bytesFromBase16(view.source.sourceBase16);
    // The deck itself is reloaded only when it has no unsaved edits.
    if (sameBytes(change.bytes, current) || view.saved !== view.revision) return;
    onDisk = change.bytes;
    await pushWith(requests.replaceSource(view.revision, change.bytes));
    // What the editor now holds is what the disk holds: not an unsaved edit.
    const reloaded = latest?.view;
    if (reloaded !== undefined && reloaded.revision !== view.revision) await pushWith(requests.storageResult(entry, reloaded.revision, true));
  }

  const stopWatching = host.onChange((changes) => { for (const change of changes) void fileChanged(change); });

  return {
    async request(request) {
      if (state === "closed") throw new TransportError("transport closed");
      const response = await call(await withProject(request));
      if (!response.ok) return response;
      spawnRenders(response.effects);
      supplyNeeds(response);
      const stored = await performStorage(response);
      void keepNodeSizes();
      return { ...stored, effects: stored.effects.filter(uiVisible) };
    },
    onPush(listener) { pushListeners.add(listener); return () => pushListeners.delete(listener); },
    onState(listener) { stateListeners.add(listener); return () => stateListeners.delete(listener); },
    state: () => state,
    close() {
      state = "closed";
      stopWatching();
      for (const listener of [...stateListeners]) listener("closed");
    },
  };
}
