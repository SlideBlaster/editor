/**
 * The two presenting windows. Both are dumb: they paint the `views` the editor window
 * broadcasts and turn keys/clicks into `command` messages. `mountAudience`/`mountConsole`
 * run inside `audience.html` / `console.html`; `createWindowOpener` runs in the editor.
 */
import { paintPlan, type PaintContext } from "../plan/paint.ts";
import { applyThemeCss } from "../theme.ts";
import type { Plan } from "../protocol/plan.ts";
import { commandForKey, createWindowState, formatTimer, presenterChannelName, routeForKey, type ChannelLike, type ChannelMessage, type PresenterCommand, type ShowTheme } from "./model.ts";

export interface WindowDeps {
  readonly doc: Document;
  readonly channel: ChannelLike;
  readonly paint: Omit<PaintContext, "doc" | "interactive" | "selection">;
  readonly now?: () => number;
}

/** The deck theme's CSS in this window, as the editor has it (once per change). */
function applyTheme(doc: Document, theme: ShowTheme | null): void {
  if (theme === null) return;
  const current = doc.getElementById(`sb-theme-${theme.name}`);
  if (current?.textContent !== theme.css) applyThemeCss(doc, theme.name, theme.css);
}

/** Speaker notes as plain flowing text: painted like a slide, then taken out of the slide frame so
 * they reflow at the console's own (large) size instead of shrinking with a themed 16:9 box. */
function notesInto(holder: HTMLElement, doc: Document, plan: Plan, paint: WindowDeps["paint"]): void {
  const scratch = doc.createElement("div");
  paintInto(scratch, doc, plan, paint);
  const text = doc.createElement("div");
  text.className = "con-notes-text";
  // Only the notes themselves: not the theme's furniture (logo, page number) or the repeated title.
  for (const item of scratch.querySelectorAll<HTMLElement>(".sb-layer-content > .sb-item")) {
    const id = item.dataset.itemId ?? "";
    if (id === "title" || id.startsWith("furniture")) continue;
    const block = doc.createElement("div");
    block.append(...item.childNodes);
    for (const styled of block.querySelectorAll<HTMLElement>("[style]")) { styled.style.removeProperty("font-size"); styled.style.removeProperty("color"); styled.style.removeProperty("font-family"); }
    text.append(block);
  }
  holder.replaceChildren(text);
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

type TauriGlobal = { core: { invoke(cmd: string, args?: Record<string, unknown>): Promise<unknown> } };
const tauriOf = (doc: Document): TauriGlobal | undefined => (doc.defaultView as unknown as { __TAURI__?: TauriGlobal } | null)?.__TAURI__;

/** The audience window's F: in the desktop shell the native window goes fullscreen (borderless, no
 * title bar); in a browser, or a shell without the command, the page does. */
function toggleFullscreen(doc: Document): void {
  const page = (): void => { if (doc.fullscreenElement === null) void doc.documentElement.requestFullscreen?.().catch(() => undefined); else void doc.exitFullscreen(); };
  const tauri = tauriOf(doc);
  if (tauri === undefined) { page(); return; }
  void tauri.core.invoke("toggle_fullscreen").catch(page);
}

/** Time the outgoing slide takes to zoom out when a route is chosen; the incoming slide zooms in for as long again. */
const routeLeaveMs = 280;

/**
 * Steps from a held key. A held key repeats faster than a step is painted, so sending every repeat
 * piles steps up and the talk keeps moving after the key is let go. A repeat is therefore sent only
 * when the step before it has been shown (or a second has passed) and not more than about eight a
 * second; a fresh press is always sent.
 */
export function heldKeySteps(send: (command: PresenterCommand) => void, now: () => number = () => performance.now()): { press(command: PresenterCommand, repeat: boolean): void; shown(): void } {
  let waiting = false;
  let sentAt = -Infinity;
  return {
    press(command, repeat) {
      const at = now();
      if (repeat && ((waiting && at - sentAt < 1000) || at - sentAt < 120)) return;
      waiting = true;
      sentAt = at;
      send(command);
    },
    shown() { waiting = false; },
  };
}

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
    applyTheme(doc, state.theme);
    paintInto(stage, doc, state.views.audience, paint);
    if (state.title) doc.title = `${state.title} — audience`;
  };
  const send = (command: PresenterCommand) => channel.postMessage({ t: "command", command });
  const keys = heldKeySteps(send);
  const choose = (route: string) => {
    choosing = true;
    stage.classList.remove("sb-route-enter");
    stage.classList.add("sb-route-leave");
    channel.postMessage({ t: "route", route });
  };
  channel.onmessage = (event) => {
    if (!state.receive(event.data as ChannelMessage)) return;
    keys.shown();
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
    if (command !== null) { event.preventDefault(); keys.press(command, event.repeat); }
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
  const keys = heldKeySteps(send);
  let fitNotesNow = (): void => undefined;
  const render = () => {
    const v = state.views;
    if (v === null) { where.textContent = state.closed ? "Presentation ended" : "Waiting for the editor…"; return; }
    applyTheme(doc, state.theme);
    paintInto(current, doc, v.audience, paint);
    if (v.notes === null) { notes.replaceChildren(); const none = doc.createElement("p"); none.className = "con-none"; none.textContent = "No notes for this slide."; notes.append(none); }
    else notesInto(notes, doc, v.notes, paint);
    fitNotesNow();
    if (v.next === null) { preview.replaceChildren(); const end = doc.createElement("p"); end.className = "con-none"; end.textContent = "End of deck."; preview.append(end); }
    else paintInto(preview, doc, v.next, paint);
    el("con-pos").textContent = `${v.cursor !== undefined ? v.cursor + 1 : "?"} / ${v.total ?? "?"}`;
    where.textContent = `Slide ${v.slide?.number ?? "?"}${v.slide ? ` / ${v.slide.count}` : ""} · step ${v.step} / ${v.steps}`;
    if (state.title) doc.title = `${state.title} — presenter`;
  };
  channel.onmessage = (event) => { if (state.receive(event.data as ChannelMessage)) { keys.shown(); render(); } };
  const choose = (route: string) => channel.postMessage({ t: "route", route });
  // Notes size. Fit (the default): the largest size up to fitMax at which this slide's notes fit
  // without scrolling, never below fitMin. A-/A+ (or - / +) pick a fixed size; Fit goes back.
  // The choice is remembered on this machine.
  const sizeKey = "sb-console-notes-px";
  const fitMin = 16, fitMax = 34;
  let manual: number | null = null;
  let notesPx = fitMax;
  try { const saved = Number(doc.defaultView?.localStorage.getItem(sizeKey)); if (saved >= 12 && saved <= 72) manual = saved; } catch { /* no storage */ }
  const show = (px: number): void => { notesPx = px; notes.style.setProperty("--con-notes-size", `${px}px`); };
  const fitNotes = (): void => {
    el("con-fit").classList.toggle("is-on", manual === null);
    if (manual !== null) { show(manual); return; }
    let lo = fitMin, hi = fitMax;
    show(hi);
    if (notes.scrollHeight <= notes.clientHeight) return;
    while (hi - lo > 1) { const mid = Math.floor((lo + hi) / 2); show(mid); if (notes.scrollHeight <= notes.clientHeight) lo = mid; else hi = mid; }
    show(lo);
  };
  fitNotesNow = fitNotes;
  const setManual = (px: number | null): void => {
    manual = px === null ? null : Math.min(72, Math.max(12, px));
    try { if (manual === null) doc.defaultView?.localStorage.removeItem(sizeKey); else doc.defaultView?.localStorage.setItem(sizeKey, String(manual)); } catch { /* no storage */ }
    fitNotes();
  };
  el("con-smaller").addEventListener("click", () => setManual(notesPx - 2));
  el("con-larger").addEventListener("click", () => setManual(notesPx + 2));
  el("con-fit").addEventListener("click", () => setManual(null));
  doc.defaultView?.addEventListener("resize", fitNotes);
  doc.addEventListener("keydown", (event) => {
    if (event.key === "+" || event.key === "=") { event.preventDefault(); setManual(notesPx + 2); }
    else if (event.key === "-") { event.preventDefault(); setManual(notesPx - 2); }
  });
  fitNotes();
  el("con-next").addEventListener("click", () => send("next"));
  el("con-prev").addEventListener("click", () => send("back"));
  el("con-audience").addEventListener("click", openAudience);
  // The audience window's fullscreen, from here: only the desktop shell can reach another window.
  const fullscreen = doc.getElementById("con-fullscreen");
  const tauri = tauriOf(doc);
  if (fullscreen !== null) {
    if (tauri === undefined) fullscreen.hidden = true;
    else fullscreen.addEventListener("click", () => { void tauri.core.invoke("toggle_fullscreen", { label: "presenter-audience" }).catch(() => undefined); });
  }
  doc.addEventListener("keydown", (event) => {
    const route = routeForKey(event.key, state.views);
    if (route !== null) { event.preventDefault(); choose(route); return; }
    const command = commandForKey(event.key);
    if (command !== null) { event.preventDefault(); (event.target as HTMLElement | null)?.blur?.(); keys.press(command, event.repeat); }
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
