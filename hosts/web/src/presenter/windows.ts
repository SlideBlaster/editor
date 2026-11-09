/**
 * The two presenting windows. Both are dumb: they paint the `views` the editor window
 * broadcasts and turn keys/clicks into `command` messages. `mountAudience`/`mountConsole`
 * run inside `audience.html` / `console.html`; `createWindowOpener` runs in the editor.
 */
import { paintPlan, type PaintContext } from "../plan/paint.ts";
import type { Plan } from "../protocol/plan.ts";
import { commandForKey, createWindowState, formatTimer, presenterChannelName, routeForKey, type ChannelLike, type ChannelMessage, type PresenterCommand } from "./model.ts";

export interface WindowDeps {
  readonly doc: Document;
  readonly channel: ChannelLike;
  readonly paint: Omit<PaintContext, "doc" | "interactive" | "selection">;
  readonly now?: () => number;
}

function paintInto(holder: HTMLElement, doc: Document, plan: Plan | null, paint: WindowDeps["paint"]): void {
  holder.replaceChildren();
  if (plan === null) return;
  try {
    holder.append(paintPlan(plan, { ...paint, doc }).element);
  } catch (error) {
    holder.append(statusNote(doc, `Could not draw this slide: ${error instanceof Error ? error.message : String(error)}`, true));
  }
}

/** A visible line of text in place of a black stage: waiting, ended, or an error. */
function statusNote(doc: Document, text: string, isError = false): HTMLElement {
  const note = doc.createElement("p");
  note.className = isError ? "sb-status-note is-error" : "sb-status-note";
  note.textContent = text;
  note.style.cssText = "color:#ddd;font:500 20px system-ui,sans-serif;text-align:center;padding:2em;margin:auto;max-width:40em;" + (isError ? "color:#ff8a80;" : "");
  return note;
}

/** The audience window's F: in the desktop shell the native window goes fullscreen (borderless, no
 * title bar); in a browser, the page does. */
function toggleFullscreen(doc: Document): void {
  const tauri = (doc.defaultView as unknown as { __TAURI__?: { core: { invoke(cmd: string): Promise<unknown> } } } | null)?.__TAURI__;
  if (tauri !== undefined) { void tauri.core.invoke("toggle_fullscreen").catch(() => undefined); return; }
  if (doc.fullscreenElement === null) void doc.documentElement.requestFullscreen(); else void doc.exitFullscreen();
}

/** Time the outgoing slide takes to zoom out when a route is chosen; the incoming slide zooms in for as long again. */
const routeLeaveMs = 280;

export function mountAudience({ doc, channel, paint }: WindowDeps): void {
  const state = createWindowState();
  const stage = doc.getElementById("stage")!;
  const hint = doc.getElementById("hint");
  const reduced = (): boolean => doc.defaultView?.matchMedia?.("(prefers-reduced-motion: reduce)")?.matches === true;
  let routeSeen: string | null | undefined;
  let choosing = false;
  const render = () => {
    if (state.views === null) {
      stage.replaceChildren(statusNote(doc, state.closed ? "Presentation ended." : "Waiting for the editor window… (press Present there, or reload this window)"));
      return;
    }
    paintInto(stage, doc, state.views.audience, paint);
    if (state.title) doc.title = `${state.title} — audience`;
  };
  const send = (command: PresenterCommand) => channel.postMessage({ t: "command", command });
  const choose = (route: string) => {
    choosing = true;
    stage.classList.remove("sb-route-enter");
    stage.classList.add("sb-route-leave");
    channel.postMessage({ t: "route", route });
  };
  channel.onmessage = (event) => {
    if (!state.receive(event.data as ChannelMessage)) return;
    const route = state.views?.route?.id ?? null;
    const selected = choosing || (routeSeen !== undefined && route !== routeSeen && route !== null);
    routeSeen = route;
    if (!selected) { render(); return; }
    // A route was chosen: the old slide zooms out, then the first slide of the chosen section zooms in.
    choosing = false;
    stage.classList.add("sb-route-leave");
    const enter = () => {
      render();
      stage.classList.remove("sb-route-leave");
      stage.classList.remove("sb-route-enter");
      void (stage as HTMLElement).offsetWidth;
      stage.classList.add("sb-route-enter");
    };
    if (reduced()) { render(); stage.classList.remove("sb-route-leave"); } else setTimeout(enter, routeLeaveMs);
  };
  doc.addEventListener("keydown", (event) => {
    if (event.key === "f" || event.key === "F") { event.preventDefault(); toggleFullscreen(doc); return; }
    const route = routeForKey(event.key, state.views);
    if (route !== null) { event.preventDefault(); choose(route); return; }
    const command = commandForKey(event.key);
    if (command !== null) { event.preventDefault(); send(command); }
  });
  doc.addEventListener("click", (event) => {
    const button = (event.target as HTMLElement | null)?.closest?.("[data-route]");
    const route = button?.getAttribute("data-route");
    if (route) { choose(route); return; }
    send("next");
  });
  setTimeout(() => hint?.classList.add("is-hidden"), 3500);
  channel.postMessage({ t: "hello", role: "audience" });
  setTimeout(() => { if (state.views === null) render(); }, 1500);
}

export function mountConsole({ doc, channel, paint, now = () => Date.now() }: WindowDeps, openAudience: () => void): void {
  const state = createWindowState();
  const el = (id: string) => doc.getElementById(id)!;
  const notes = el("con-notes");
  const preview = el("con-preview");
  const current = el("con-current");
  const where = el("con-where");
  const timer = el("con-timer");
  const send = (command: PresenterCommand) => channel.postMessage({ t: "command", command });
  const render = () => {
    const v = state.views;
    if (v === null) { where.textContent = state.closed ? "Presentation ended" : "Waiting for the editor…"; return; }
    paintInto(current, doc, v.audience, paint);
    if (v.notes === null) { notes.replaceChildren(); const none = doc.createElement("p"); none.className = "con-none"; none.textContent = "No notes for this slide."; notes.append(none); }
    else paintInto(notes, doc, v.notes, paint);
    if (v.next === null) { preview.replaceChildren(); const end = doc.createElement("p"); end.className = "con-none"; end.textContent = "End of deck."; preview.append(end); }
    else paintInto(preview, doc, v.next, paint);
    el("con-pos").textContent = `${v.cursor !== undefined ? v.cursor + 1 : "?"} / ${v.total ?? "?"}`;
    where.textContent = `Slide ${v.slide?.number ?? "?"}${v.slide ? ` / ${v.slide.count}` : ""} · step ${v.step} / ${v.steps}`;
    if (state.title) doc.title = `${state.title} — presenter`;
  };
  channel.onmessage = (event) => { if (state.receive(event.data as ChannelMessage)) render(); };
  const choose = (route: string) => channel.postMessage({ t: "route", route });
  el("con-next").addEventListener("click", () => send("next"));
  el("con-prev").addEventListener("click", () => send("back"));
  el("con-audience").addEventListener("click", openAudience);
  doc.addEventListener("keydown", (event) => {
    const route = routeForKey(event.key, state.views);
    if (route !== null) { event.preventDefault(); choose(route); return; }
    const command = commandForKey(event.key);
    if (command !== null) { event.preventDefault(); (event.target as HTMLElement | null)?.blur?.(); send(command); }
  });
  doc.addEventListener("click", (event) => {
    const route = (event.target as HTMLElement | null)?.closest?.("[data-route]")?.getAttribute("data-route");
    if (route) choose(route);
  });
  setInterval(() => { if (state.timerOriginMs !== null) timer.textContent = formatTimer(now() - state.timerOriginMs); }, 500);
  channel.postMessage({ t: "hello", role: "console" });
  render();
}

export interface WindowOpener {
  openConsole(): boolean;
  openAudience(): boolean;
}

/** Browser opener (a plain tab/popup); the Tauri shell supplies its own that creates native windows. */
export function createBrowserWindowOpener(base: string, open: (url: string, name: string, features: string) => unknown = (u, n, f) => window.open(u, n, f)): WindowOpener {
  return {
    openConsole: () => open(`${base}console.html`, "sb-presenter-console", "width=1120,height=760") !== null,
    openAudience: () => open(`${base}audience.html`, "sb-presenter-audience", "width=1280,height=720") !== null,
  };
}

export const openChannel = (): ChannelLike => new BroadcastChannel(presenterChannelName) as unknown as ChannelLike;
