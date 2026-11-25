/**
 * Client for `slideblaster.cap/1` (`docs/specs/cap-websocket.md`, lane B): project storage,
 * file watch and extension providers over `ws://<host>/cap`. Requests are pipelined and
 * correlated by `id`; unsolicited `hello`/`watch` events are surfaced to listeners.
 *
 * In the Desktop build the core talks to storage and providers itself, so the UI uses this
 * client for what the core does not drive (provider status, project listing) and for the
 * browser-only fallback (`relayBlockRender`).
 */
import type { SocketLike } from "../transport/transport.ts";

export interface ProviderInfo {
  readonly id: string;
  readonly version: string;
  readonly slot: string;
  readonly kinds: readonly string[];
  readonly output: string;
  readonly available: boolean;
  readonly missingTools: readonly string[];
}

export type CapEvent =
  | { readonly event: "hello"; readonly protocol: string; readonly version: string; readonly root: string; readonly providers: readonly ProviderInfo[] }
  | { readonly event: "watch"; readonly changes: readonly { readonly path: string; readonly change: "created" | "modified" | "deleted" }[] };

export class CapError extends Error {
  readonly code: string;
  constructor(code: string, message: string) { super(message); this.name = "CapError"; this.code = code; }
}

export interface CapClient {
  ready(): Promise<CapEvent & { event: "hello" }>;
  call<T = Record<string, unknown>>(op: string, fields?: Record<string, unknown>): Promise<T & { ok: true; id: number }>;
  listProject(path?: string, recursive?: boolean): Promise<{ path: string; kind: "file" | "dir"; size?: number }[]>;
  read(path: string): Promise<Uint8Array>;
  save(path: string, expected: Uint8Array | null, content: Uint8Array): Promise<{ sha256: string; size: number }>;
  subscribeWatch(): Promise<void>;
  providers(): Promise<ProviderInfo[]>;
  blockRender(request: BlockRenderRequest): Promise<BlockRenderResponse>;
  onEvent(listener: (event: CapEvent) => void): () => void;
  state(): "connecting" | "open" | "closed";
  close(): void;
}

export interface BlockRenderRequest {
  readonly ticket: string;
  readonly slot: "block.render";
  readonly kind: string;
  readonly fingerprint?: string;
  readonly deadline?: number;
  readonly input: Record<string, unknown>;
}

export interface BlockRenderResponse {
  readonly ticket: string;
  readonly fingerprint: string;
  readonly artifact?: { readonly mime: string; readonly encoding: "utf8" | "base64"; readonly data: string; readonly size: number; readonly provenance?: Record<string, unknown> };
  readonly diagnostics?: readonly { readonly severity: string; readonly code: string; readonly message: string; readonly sourceLine?: number; readonly texLine?: number }[];
  readonly absence?: { readonly reason: "tool_missing" | "no_provider" | "timeout" | "limit_exceeded"; readonly provider?: string; readonly tool?: string };
}

export function capUrlFor(location: { protocol: string; host: string; search: string }): string {
  const override = new URLSearchParams(location.search).get("cap");
  if (override !== null) return override;
  return `${location.protocol === "https:" ? "wss" : "ws"}://${location.host}/cap`;
}

const toBase64 = (bytes: Uint8Array): string => { let s = ""; for (const b of bytes) s += String.fromCharCode(b); return btoa(s); };
const fromBase64 = (text: string): Uint8Array => Uint8Array.from(atob(text), (c) => c.charCodeAt(0));

export function createCapClient(url: string, createSocket: (url: string) => SocketLike = (u) => new WebSocket(u) as unknown as SocketLike): CapClient {
  const socket = createSocket(url);
  const pending = new Map<number, { resolve: (value: any) => void; reject: (error: Error) => void }>();
  const listeners = new Set<(event: CapEvent) => void>();
  let nextId = 1;
  let state: "connecting" | "open" | "closed" = "connecting";
  let helloValue: (CapEvent & { event: "hello" }) | null = null;
  let helloResolve: (value: CapEvent & { event: "hello" }) => void = () => {};
  let helloReject: (error: Error) => void = () => {};
  const hello = new Promise<CapEvent & { event: "hello" }>((resolve, reject) => { helloResolve = resolve; helloReject = reject; });
  hello.catch(() => undefined);

  socket.onopen = () => { state = "open"; };
  socket.onmessage = (event) => {
    if (typeof event.data !== "string") return;
    let body: any;
    try { body = JSON.parse(event.data); } catch { return; }
    if (typeof body !== "object" || body === null) return;
    if (typeof body.event === "string") {
      if (body.event === "hello") { helloValue = body; helloResolve(body); }
      if (body.event === "hello" || body.event === "watch") for (const l of [...listeners]) l(body as CapEvent);
      return;
    }
    const entry = pending.get(body.id);
    if (entry === undefined) return;
    pending.delete(body.id);
    if (body.ok === true) entry.resolve(body);
    else entry.reject(new CapError(body.error?.code ?? "bad_response", body.error?.message ?? "capability request failed"));
  };
  socket.onclose = () => {
    state = "closed";
    const error = new CapError("closed", "The capability connection closed");
    for (const entry of pending.values()) entry.reject(error);
    pending.clear();
    helloReject(error);
  };
  socket.onerror = () => {};

  function call<T>(op: string, fields: Record<string, unknown> = {}): Promise<T & { ok: true; id: number }> {
    if (state === "closed") return Promise.reject(new CapError("closed", "The capability connection is closed"));
    const id = nextId++;
    return new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject });
      try { socket.send(JSON.stringify({ id, op, ...fields })); } catch (failure) { pending.delete(id); reject(failure instanceof Error ? failure : new CapError("send_failed", "send failed")); }
    });
  }

  return {
    ready: () => helloValue !== null ? Promise.resolve(helloValue) : hello,
    call,
    async listProject(path = "", recursive = true) { return (await call<{ entries: any[] }>("storage.list", { path, recursive })).entries; },
    async read(path) { return fromBase64((await call<{ contentBase64: string }>("storage.read", { path })).contentBase64); },
    async save(path, expected, content) {
      const r = await call<{ sha256: string; size: number }>("storage.save", { path, expectedBase64: expected === null ? null : toBase64(expected), contentBase64: toBase64(content) });
      return { sha256: r.sha256, size: r.size };
    },
    async subscribeWatch() { await call("watch.subscribe"); },
    async providers() { return (await call<{ providers: ProviderInfo[] }>("providers.list")).providers; },
    async blockRender(request) { return await call<BlockRenderResponse>("block.render", request as unknown as Record<string, unknown>); },
    onEvent(listener) { listeners.add(listener); return () => listeners.delete(listener); },
    state: () => state,
    close: () => socket.close(),
  };
}

/**
 * Browser-only relay of a core `block.render` effect (session/1 section 3): send the
 * request over `/cap` (or answer typed absence at once when there is no provider) and
 * translate the outcome into the fields of a `provider_result` request. The host adds no
 * judgement: tickets and fingerprints are echoed, bytes are re-encoded, nothing is cached.
 */
export async function relayBlockRender(
  effect: { ticket: number; fingerprint: string; request: Record<string, unknown> },
  cap: Pick<CapClient, "blockRender"> | null,
): Promise<Record<string, unknown>> {
  // A `provider_result` body is closed: each diagnostic has exactly these five fields.
  const diagnostic = (d: { severity?: string; code?: string; message?: string; sourceLine?: number; texLine?: number }, absent: boolean): Record<string, unknown> => {
    const line = d.sourceLine ?? d.texLine;
    return { severity: d.severity ?? "error", code: d.code ?? "provider", message: d.message ?? "", line: typeof line === "number" && Number.isInteger(line) && line >= 0 ? line : null, absent };
  };
  const absent = (message: string): Record<string, unknown> => ({ diagnostics: [diagnostic({ severity: "warning", code: "provider_absent", message }, true)] });
  if (cap === null) return absent("No extension provider is connected; figures stay placeholders");
  let response: BlockRenderResponse;
  try {
    // The core's fingerprint is not the provider's (that one adds the provider's identity), so it is not claimed.
    const { fingerprint: _claimed, ...request } = effect.request as Record<string, unknown>;
    response = await cap.blockRender({ ...(request as Omit<BlockRenderRequest, "ticket" | "fingerprint">), ticket: `t-${effect.ticket}` } as BlockRenderRequest);
  } catch (failure) {
    return absent(failure instanceof Error ? failure.message : "provider request failed");
  }
  if (response.ticket !== `t-${effect.ticket}`) return absent("provider answered a different request");
  if (response.absence !== undefined) {
    const said = response.diagnostics ?? [];
    return { diagnostics: said.length > 0 ? said.map((d) => diagnostic(d, true)) : [diagnostic({ severity: "warning", code: "provider.absent", message: `provider absent: ${response.absence.reason}` }, true)] };
  }
  if (response.artifact !== undefined) {
    const bytes = response.artifact.encoding === "base64" ? fromBase64(response.artifact.data) : new TextEncoder().encode(response.artifact.data);
    const intrinsic = response.artifact.mime === "image/svg+xml" ? svgIntrinsicSize(new TextDecoder().decode(bytes)) : null;
    return {
      artifact: {
        mime: response.artifact.mime,
        bytesBase16: [...bytes].map((b) => b.toString(16).padStart(2, "0")).join(""),
        width: intrinsic?.width ?? 100,
        height: intrinsic?.height ?? 100,
        provenance: String(response.artifact.provenance?.provider ?? "provider"),
      },
    };
  }
  return { diagnostics: (response.diagnostics ?? []).map((d) => diagnostic(d, false)) };
}

/** Intrinsic size from the root `width`/`height` or `viewBox`; a measurement, not a parse of the deck. */
export function svgIntrinsicSize(svg: string): { width: number; height: number } | null {
  const root = /<svg\b[^>]*>/i.exec(svg)?.[0];
  if (root === undefined) return null;
  const num = (name: string) => { const m = new RegExp(`\\s${name}\\s*=\\s*["']\\s*([0-9]*\\.?[0-9]+)\\s*(pt|px)?\\s*["']`, "i").exec(root); return m === null ? null : Number(m[1]) * (m[2]?.toLowerCase() === "pt" ? 96 / 72 : 1); };
  const w = num("width"); const h = num("height");
  if (w !== null && h !== null) return { width: w, height: h };
  const vb = /viewBox\s*=\s*["']\s*[-0-9.]+[ ,]+[-0-9.]+[ ,]+([0-9.]+)[ ,]+([0-9.]+)/i.exec(root);
  return vb === null ? null : { width: Number(vb[1]), height: Number(vb[2]) };
}
