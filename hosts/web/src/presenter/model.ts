/**
 * Presenter synchronisation (ported from editor/packages/app/src/presenter.ts, ADR 0019).
 *
 * The cursor is the core's: `Presentation.Presenter` is a clamped zipper over the
 * audience-capped beat list and every move is a `present_*` request. The editor window is
 * the hub: it forwards window commands to the core and broadcasts the core's
 * `view.presenter` over a BroadcastChannel to the audience window and the console, which
 * only paint what they receive. Both therefore always show the same cursor; notes are
 * projected at the audience's step and can never add beats.
 */
import type { Request, SessionResponse, PresenterView, NavigatorItem } from "../protocol/session.ts";
import { requests } from "../protocol/session.ts";

export const presenterChannelName = "sb-presenter";

export type PresenterCommand = "next" | "back" | "home" | "end";

/** The deck theme's CSS, so the presenter windows draw slides exactly as the editor and the PDF do. */
export interface ShowTheme { readonly name: string; readonly css: string }

export type ShowMessage =
  | { readonly t: "views"; readonly hub?: string; readonly seq: number; readonly views: PresenterView; readonly timerOriginMs: number; readonly title: string; readonly theme?: ShowTheme | null }
  | { readonly t: "closed"; readonly hub?: string; readonly seq: number };
export type WindowMessage =
  | { readonly t: "command"; readonly command: PresenterCommand }
  | { readonly t: "route"; readonly route: string }
  | { readonly t: "hello"; readonly role: "audience" | "console" };
export type ChannelMessage = ShowMessage | WindowMessage;

export interface ChannelLike {
  postMessage(message: ChannelMessage): void;
  onmessage: ((event: { data: ChannelMessage }) => void) | null;
}

export interface PresenterHubOptions {
  readonly channel: ChannelLike;
  readonly request: (request: Request) => Promise<SessionResponse>;
  /** The current navigator, to resolve `home` and `end` into core `present_goto` targets. */
  readonly navigator: () => readonly Pick<NavigatorItem, "frame" | "steps">[];
  readonly title: () => string;
  /** The deck theme's CSS as the editor applied it (null: the built-in look). */
  readonly theme?: () => ShowTheme | null;
  readonly now?: () => number;
  /** Raised when a command fails (stale or rejected); the hub stays usable. */
  readonly onError?: (message: string) => void;
}

export interface PresenterHub {
  /** Start presenting at a frame (or the first); resolves once windows were told. */
  open(startFrame?: string): Promise<void>;
  /** Feed a response that carries `view.presenter` (also called for pushes). */
  accept(response: SessionResponse): void;
  /** Resolves when every queued command has been answered. */
  idle(): Promise<void>;
  close(): Promise<void>;
  /** Where the presentation is (null when not presenting). */
  readonly position: { readonly frame: string; readonly step: number } | null;
  /** After a reconnect (a restarted sb has no presentation): reopen at the last position. */
  resume(): Promise<void>;
  /** Send the current slide again (the theme changed). */
  refresh(): void;
  readonly timerOriginMs: number | null;
}

export function createPresenterHub(options: PresenterHubOptions): PresenterHub {
  const now = options.now ?? (() => Date.now());
  const channel = options.channel;
  let seq = 0;
  // Each editor page is its own hub: a reloaded editor restarts seq at 1, and windows
  // that are still open must not ignore it as stale.
  const hub = Math.random().toString(36).slice(2);
  let timerOrigin: number | null = null;
  let last: PresenterView | null = null;
  // The last position, kept across a reconnect so `resume` can restore it.
  let position: { frame: string; step: number } | null = null;
  let closing = false;
  let queue: Promise<void> = Promise.resolve();

  function broadcast(): void {
    if (last === null || timerOrigin === null) return;
    seq += 1;
    channel.postMessage({ t: "views", hub, seq, views: last, timerOriginMs: timerOrigin, title: options.title(), theme: options.theme?.() ?? null });
  }

  function accept(response: SessionResponse): void {
    if (!response.ok) return;
    if (response.view.presenter === null) {
      // Only an explicit close ends the show; a core that lost it (restart) is resumed instead,
      // so the windows keep the last slide rather than going blank.
      if (last !== null && (closing || timerOrigin === null)) { last = null; position = null; seq += 1; channel.postMessage({ t: "closed", hub, seq }); }
      return;
    }
    last = response.view.presenter;
    position = { frame: last.frame, step: last.step };
    broadcast();
  }

  async function send(request: Request): Promise<void> {
    try {
      const response = await options.request(request);
      if (!response.ok) options.onError?.(response.error.message);
      else accept(response);
    } catch (failure) {
      options.onError?.(failure instanceof Error ? failure.message : "presenter request failed");
    }
  }

  const enqueue = (request: Request): Promise<void> => (queue = queue.then(() => send(request)));

  /** The navigator items in the active route's order (file order when the core names no route). */
  function orderedItems(): readonly Pick<NavigatorItem, "frame" | "steps">[] {
    const items = options.navigator();
    const frames = last?.route?.frames;
    if (frames === undefined || frames.length === 0) return items;
    return frames.flatMap((frame) => items.filter((item) => item.frame === frame));
  }

  function requestFor(command: PresenterCommand): Request | null {
    switch (command) {
      case "next": return requests.presentStep("next");
      case "back": return requests.presentStep("previous");
      case "home": { const first = orderedItems()[0]; return first === undefined ? null : requests.presentGoto(first.frame, 1); }
      case "end": { const items = orderedItems(); const lastItem = items[items.length - 1]; return lastItem === undefined ? null : requests.presentGoto(lastItem.frame, lastItem.steps); }
    }
  }

  channel.onmessage = (event) => {
    const message = event.data;
    if (message.t === "route") {
      void enqueue(requests.presentRoute(message.route));
    } else if (message.t === "command") {
      const request = requestFor(message.command);
      if (request !== null) void enqueue(request);
    } else if (message.t === "hello") {
      broadcast();
    }
  };

  return {
    async open(startFrame) {
      timerOrigin = now();
      await enqueue(requests.presentOpen(startFrame));
    },
    accept,
    idle: () => queue,
    async close() {
      closing = true;
      await enqueue(requests.presentClose());
      closing = false;
      last = null;
      position = null;
      timerOrigin = null;
    },
    get position() { return position; },
    async resume() {
      if (timerOrigin === null || position === null) return;
      const { frame, step } = position;
      await enqueue(requests.presentOpen(frame));
      if (step > 1) await enqueue(requests.presentGoto(frame, step));
    },
    refresh: broadcast,
    get timerOriginMs() { return timerOrigin; },
  };
}

/** What a presenting window knows: the latest accepted views, ignoring stale or reordered messages. */
export interface WindowState {
  readonly views: PresenterView | null;
  readonly timerOriginMs: number | null;
  readonly title: string;
  readonly theme: ShowTheme | null;
  readonly closed: boolean;
  /** Apply one message; returns true when the visible state changed. */
  receive(message: ChannelMessage): boolean;
}

export function createWindowState(): WindowState & { views: PresenterView | null; timerOriginMs: number | null; title: string; theme: ShowTheme | null; closed: boolean } {
  let seq = -1;
  let hub: string | undefined;
  const state = {
    views: null as PresenterView | null,
    timerOriginMs: null as number | null,
    title: "",
    theme: null as ShowTheme | null,
    closed: false,
    receive(message: ChannelMessage): boolean {
      if (message.t !== "views" && message.t !== "closed") return false;
      if (message.hub !== hub) { hub = message.hub; seq = -1; }
      if (message.seq <= seq) return false;
      seq = message.seq;
      if (message.t === "closed") { state.closed = true; state.views = null; return true; }
      state.closed = false;
      state.views = message.views;
      state.timerOriginMs = message.timerOriginMs;
      state.title = message.title;
      state.theme = message.theme ?? null;
      return true;
    },
  };
  return state;
}

/** Key bindings shared by both windows (ED presenter keys). */
export function commandForKey(key: string): PresenterCommand | null {
  switch (key) {
    case "ArrowRight": case "ArrowDown": case "PageDown": case " ": return "next";
    case "ArrowLeft": case "ArrowUp": case "PageUp": return "back";
    case "Home": return "home";
    case "End": return "end";
    default: return null;
  }
}

/** A digit key 1..9 on a choice slide selects the n-th route choice; anything else selects nothing. */
export function routeForKey(key: string, views: PresenterView | null): string | null {
  if (views === null || !/^[1-9]$/.test(key)) return null;
  return views.choices?.[Number(key) - 1]?.route ?? null;
}

export function formatTimer(elapsedMs: number): string {
  const total = Math.max(0, Math.floor(elapsedMs / 1000));
  const h = Math.floor(total / 3600);
  const mm = String(Math.floor((total % 3600) / 60)).padStart(2, "0");
  const ss = String(total % 60).padStart(2, "0");
  return h > 0 ? `${h}:${mm}:${ss}` : `${mm}:${ss}`;
}

/** In-memory channel bus for tests: every endpoint hears every other endpoint, in order. */
export function createChannelBus(): { endpoint(): ChannelLike } {
  const endpoints: ChannelLike[] = [];
  return {
    endpoint() {
      const endpoint: ChannelLike = {
        onmessage: null,
        postMessage(message) {
          for (const other of endpoints) if (other !== endpoint) other.onmessage?.({ data: structuredClone(message) });
        },
      };
      endpoints.push(endpoint);
      return endpoint;
    },
  };
}
