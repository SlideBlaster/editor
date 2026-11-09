/**
 * The one seam between the UI and the Haskell core. The alpha (Desktop) implementation is
 * `WebSocketTransport` to `sb serve`'s `/session`; the later in-page Wasm build (W-web)
 * drops in another `SessionTransport` without touching the UI.
 */
import { decodeSessionResponse, type Request, type SessionResponse, type SessionSuccess } from "../protocol/session.ts";

export type ConnectionState = "connecting" | "open" | "reconnecting" | "closed";

export interface SessionTransport {
  /** Send one request; requests are serialised (the core answers in lock step). */
  request(request: Request): Promise<SessionResponse>;
  /** Unsolicited `view_updated` frames (figure finished, file changed on disk). */
  onPush(listener: (push: SessionSuccess) => void): () => void;
  onState(listener: (state: ConnectionState) => void): () => void;
  state(): ConnectionState;
  close(): void;
}

export class TransportError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "TransportError";
  }
}

/** The subset of the WebSocket API the transport uses; lets tests inject a fake. */
export interface SocketLike {
  readyState: number;
  send(data: string): void;
  close(): void;
  onopen: ((event: unknown) => void) | null;
  onclose: ((event: unknown) => void) | null;
  onerror: ((event: unknown) => void) | null;
  onmessage: ((event: { data: unknown }) => void) | null;
}

export interface WebSocketTransportOptions {
  readonly url: string;
  readonly createSocket?: (url: string) => SocketLike;
  readonly schedule?: (callback: () => void, milliseconds: number) => unknown;
  readonly cancel?: (handle: unknown) => void;
  /** Backoff bounds in milliseconds. */
  readonly minDelay?: number;
  readonly maxDelay?: number;
}

const socketOpen = 1;

export function createWebSocketTransport(options: WebSocketTransportOptions): SessionTransport {
  const createSocket = options.createSocket ?? ((url: string) => new WebSocket(url) as unknown as SocketLike);
  const schedule = options.schedule ?? ((cb: () => void, ms: number) => setTimeout(cb, ms));
  const cancel = options.cancel ?? ((h: unknown) => clearTimeout(h as ReturnType<typeof setTimeout>));
  const minDelay = options.minDelay ?? 250;
  const maxDelay = options.maxDelay ?? 5000;
  const pushListeners = new Set<(push: SessionSuccess) => void>();
  const stateListeners = new Set<(state: ConnectionState) => void>();
  const queue: { request: Request; resolve: (r: SessionResponse) => void; reject: (e: Error) => void }[] = [];
  let socket: SocketLike | null = null;
  let current: (typeof queue)[number] | null = null;
  let state: ConnectionState = "connecting";
  let delay = minDelay;
  let timer: unknown = null;
  let closedByUser = false;

  function setState(next: ConnectionState): void {
    if (state === next) return;
    state = next;
    for (const listener of [...stateListeners]) listener(next);
  }

  function pump(): void {
    if (current !== null || socket === null || socket.readyState !== socketOpen) return;
    const next = queue.shift();
    if (next === undefined) return;
    current = next;
    try {
      socket.send(JSON.stringify(next.request));
    } catch (failure) {
      current = null;
      next.reject(new TransportError(failure instanceof Error ? failure.message : "send failed"));
      pump();
    }
  }

  function connect(): void {
    const created = createSocket(options.url);
    socket = created;
    created.onopen = () => {
      delay = minDelay;
      setState("open");
      pump();
    };
    created.onmessage = (event) => {
      if (typeof event.data !== "string") return;
      let response: SessionResponse;
      try {
        response = decodeSessionResponse(event.data);
      } catch (failure) {
        const pending = current;
        current = null;
        pending?.reject(failure instanceof Error ? failure : new TransportError("bad frame"));
        pump();
        return;
      }
      if (response.ok && response.kind === "view_updated") {
        for (const listener of [...pushListeners]) listener(response);
        return;
      }
      const pending = current;
      current = null;
      pending?.resolve(response);
      pump();
    };
    created.onclose = () => {
      if (socket !== created) return;
      socket = null;
      const pending = current;
      current = null;
      pending?.reject(new TransportError("The connection to the SlideBlaster core dropped"));
      if (closedByUser) {
        setState("closed");
        return;
      }
      setState("reconnecting");
      timer = schedule(() => { timer = null; connect(); }, delay);
      delay = Math.min(maxDelay, delay * 2);
    };
    created.onerror = () => { /* onclose follows and drives reconnection */ };
  }

  connect();

  return {
    request(request) {
      if (closedByUser) return Promise.reject(new TransportError("transport closed"));
      return new Promise<SessionResponse>((resolve, reject) => {
        queue.push({ request, resolve, reject });
        pump();
      });
    },
    onPush(listener) { pushListeners.add(listener); return () => pushListeners.delete(listener); },
    onState(listener) { stateListeners.add(listener); return () => stateListeners.delete(listener); },
    state: () => state,
    close() {
      closedByUser = true;
      if (timer !== null) cancel(timer);
      const pending = [current, ...queue.splice(0)];
      current = null;
      for (const item of pending) item?.reject(new TransportError("transport closed"));
      socket?.close();
      setState("closed");
    },
  };
}

/** `ws://host/session` for the page's own origin (Tauri webview or browser tab on `sb serve`). */
export function sessionUrlFor(location: { protocol: string; host: string; search: string }): string {
  const override = new URLSearchParams(location.search).get("session");
  if (override !== null) return override;
  return `${location.protocol === "https:" ? "wss" : "ws"}://${location.host}/session`;
}
