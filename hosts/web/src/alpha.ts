/**
 * Alpha shell: wires the session/1 transport (WebSocket to `sb serve`, or the fixture core
 * with `?fixture=1`) to the CM6 pane, the continuous deck view and the presenter hub.
 * The shell forwards facts and adopts what the core returns; it never parses the deck,
 * mints ids or computes revisions.
 */
import { createDomMeasurer, type DomMeasurer } from "./measure.ts";
import { ensureKatexCss } from "./content/katex-css.ts";
import { createShikiHighlighter } from "./content/highlight.ts";
import { katexProvider } from "./content/math.ts";
import { capUrlFor, createCapClient } from "./cap/client.ts";
import { createFakeCore } from "./fixture/fake-core.ts";
import { createPresenterHub, type PresenterHub } from "./presenter/model.ts";
import { createBrowserWindowOpener, openChannel, type WindowOpener } from "./presenter/windows.ts";
import { bytesFromBase16, requests, type Effect, type Request, type SessionResponse, type SessionSuccess, type View } from "./protocol/session.ts";
import { createSourcePane } from "./source/pane.ts";
import { applyThemeCss, loadTheme } from "./theme.ts";
import { createWebSocketTransport, sessionUrlFor, type SessionTransport } from "./transport/transport.ts";
import { createDeckView } from "./ui/deck-view.ts";
import { exportPdf, pdfStatus } from "./ui/export-pdf.ts";
import { installFreeZoom, zoomStep } from "./ui/free-zoom.ts";
import { currentFolder, installSidebar, resolveDeckFolder, type ShellBridge } from "./ui/sidebar.ts";
import { installStyleToolbar } from "./ui/style-toolbar.ts";

const doc = document;
const $ = <T extends HTMLElement>(id: string): T => doc.getElementById(id) as T;
const decoder = new TextDecoder();
const encoder = new TextEncoder();
const params = new URLSearchParams(location.search);
const base = doc.baseURI.replace(/[?#].*$/, "").replace(/[^/]*$/, "");

declare global {
  interface Window {
    /** Set by the Tauri shell so presenter windows are native windows. */
    __SB_WINDOW_OPENER__?: WindowOpener;
    /** Set by the Tauri shell: the presentations list and switching. Absent in a plain browser. */
    __SB_SHELL__?: ShellBridge;
  }
}

ensureKatexCss(doc);
const paintBase = { math: katexProvider, highlighter: createShikiHighlighter() };
const status = (message: string): void => { $("status").textContent = message; };

function banner(message: string | null): void {
  const el = $("banner");
  el.hidden = message === null;
  el.textContent = message ?? "";
}

async function makeTransport(): Promise<SessionTransport> {
  if (params.get("fixture") === "1") {
    const response = await fetch(new URL("./fixtures/plans/sample-deck.slideBlaster.md", doc.baseURI));
    return createFakeCore({ source: new Uint8Array(await response.arrayBuffer()), figureDelayMs: 900 });
  }
  return createWebSocketTransport({ url: sessionUrlFor(location) });
}

/** Ask `/cap` which deck the served project holds (default, revisitable: first `*.slideBlaster.md`). */
async function discoverEntry(): Promise<string> {
  const cap = createCapClient(capUrlFor(location));
  try {
    await cap.ready();
    const files = await cap.listProject("", true);
    const deck = files.filter((f) => f.kind === "file" && f.path.endsWith(".slideBlaster.md")).map((f) => f.path).sort()[0];
    return deck ?? "deck.slideBlaster.md";
  } catch {
    return "talk.slideBlaster.md";
  } finally {
    cap.close();
  }
}

async function main(): Promise<void> {
  const transport = await makeTransport();
  const fixture = params.get("fixture") === "1";
  const pane = createSourcePane($("source"));
  let view: View | null = null;
  let hub: PresenterHub | null = null;
  let presenting = false;
  let windowsOpen = false;

  const opener = window.__SB_WINDOW_OPENER__ ?? createBrowserWindowOpener(base);
  const openWindows = (): void => {
    if (windowsOpen) return;
    windowsOpen = true;
    if (!opener.openConsole() || !opener.openAudience()) status("Allow pop-ups to open the presenter windows");
  };

  // --- request plumbing ---------------------------------------------------------------
  async function send(request: Request): Promise<SessionResponse> {
    const response = await transport.request(request);
    if (response.ok) await adopt(response);
    return response;
  }

  async function adopt(response: SessionSuccess): Promise<void> {
    const next = response.view;
    view = next;
    if (next.source !== undefined) pane.setText(decoder.decode(bytesFromBase16(next.source.sourceBase16)));
    pane.setDiagnostics(next.diagnostics);
    pane.setDirty(next.revision !== next.saved);
    hub?.accept(response);
    chrome(next);
    loadThemeFor(next);
    await deck.update(next, next.navigator.activeFrame);
    for (const effect of response.effects) await handleEffect(effect);
  }

  let themeLoaded = "";
  function loadThemeFor(v: View): void {
    const name = v.frontmatter.theme;
    if (!name || name === themeLoaded || !/^[a-z0-9-]+$/.test(name)) return;
    themeLoaded = name;
    reloadTheme(name);
  }

  // The deck's own theme (themes/<name>/ next to the deck, as the core and the PDF export
  // read it) wins over the bundled copy; it is fetched again whenever a theme file changes.
  function reloadTheme(name: string): void {
    const deckDir = entry.includes("/") ? entry.slice(0, entry.lastIndexOf("/") + 1) : "";
    const fetcher = (url: string) => fetch(url, { cache: "no-store" });
    loadTheme(`${base}project/${deckDir}`, name, fetcher)
      .catch(() => loadTheme(`${base}dist/`, name, fetcher))
      .then((theme) => { applyThemeCss(doc, name, theme.css); measurer.reset(); }, () => { /* built-in minimal theme */ });
  }

  async function handleEffect(effect: Effect): Promise<void> {
    switch (effect.kind) {
      case "measure": {
        const results = await measurer.measureAll(effect.items as never);
        void enqueue(() => send(requests.measurementResult(effect.ticket, results)));
        break;
      }
      case "present":
        if (effect.op === "open") openWindows();
        if (effect.op === "close") { presenting = false; windowsOpen = false; }
        break;
      case "focus_node": {
        const span = (effect as { span?: { start: number; end: number } }).span;
        if (span !== undefined) pane.revealBytes(span);
        break;
      }
      case "slide_selected": case "slide_created": {
        const frame = (effect as { frame?: string }).frame;
        if (frame !== undefined) deck.scrollToFrame(frame, "smooth");
        break;
      }
      default: break;
    }
  }

  // --- edits: exact-byte, last-to-first, one at a time ---------------------------------
  let chain: Promise<unknown> = Promise.resolve();
  const enqueue = <T,>(job: () => Promise<T>): Promise<T> => {
    const run = chain.then(job, job);
    chain = run.catch(() => undefined);
    return run;
  };

  async function resync(reason: string): Promise<void> {
    const snapshot = await transport.request(requests.workspaceSnapshot());
    if (!snapshot.ok) return status(`Out of sync (${reason}) and the core is unreachable`);
    const result = await send(requests.replaceSource(snapshot.view.revision, encoder.encode(pane.getText())));
    status(result.ok ? `Resynchronised the source (${reason})` : result.error.message);
  }

  pane.onEdit((edits) => {
    void enqueue(async () => {
      for (const edit of edits) {
        if (view === null) return;
        const response = await send(requests.applySourceReplace(view.revision, edit.range, edit.expected, edit.replacement));
        if (!response.ok) {
          if (["stale_revision", "expected_mismatch"].includes(response.error.code)) { await resync(response.error.code); return; }
          status(response.error.message);
          return;
        }
      }
    });
  });

  // --- views ----------------------------------------------------------------------------
  const deck = createDeckView({
    doc, scroller: $("deck"), canvas: $("deck-canvas"), rail: $("slide-items"), paint: paintBase,
    sink: {
      pointer: (fact) => enqueue(() => send(requests.pointerEvent(fact))),
      activate: (surface, nodeId) => enqueue(() => send(requests.activateNode(surface, nodeId))),
    },
    onSelect: (frame) => { void enqueue(() => send(requests.selectSlide(frame))); },
    // An included slide's "open": in the desktop shell, switch to the deck it comes from.
    onOpenOrigin: window.__SB_SHELL__ === undefined ? undefined : (deckPath) => {
      const shell = window.__SB_SHELL__!;
      void shell.listPresentations().then((items) => {
        const here = currentFolder(items);
        if (here === null) return status("Cannot tell which deck is open");
        return shell.openPresentation(resolveDeckFolder(here, deckPath));
      }).catch((e) => status(e instanceof Error ? e.message : String(e)));
    },
  });
  $("deck").addEventListener("scroll", () => deck.syncRail(), { passive: true });
  const measurer: DomMeasurer = createDomMeasurer({ doc, paint: paintBase });

  const button = (id: string): HTMLButtonElement => $<HTMLButtonElement>(id);
  function chrome(v: View): void {
    const enabled = (name: string): boolean => v.commands[name]?.enabled === true;
    button("undo").disabled = !enabled("undo");
    button("redo").disabled = !enabled("redo");
    button("save").disabled = !enabled("save") && v.revision === v.saved;
    const create = enabled("new_slide") || enabled("create_slide") || enabled("add_slide");
    button("new-slide").disabled = !create;
    button("deck-add").disabled = !create;
    button("present-btn").disabled = !v.ready;
    button("export-pdf").disabled = !v.ready || fixture || exporting;
    $("doc-title").textContent = v.frontmatter.title || "Untitled";
    $("doc-title").dataset.dirty = String(v.revision !== v.saved);
    const errors = v.diagnostics.filter((d) => d.severity === "error").length;
    const warnings = v.diagnostics.filter((d) => d.severity === "warning").length;
    const summary = $("diagnostics-summary");
    summary.textContent = errors + warnings === 0 ? "" : `${errors} error${errors === 1 ? "" : "s"}, ${warnings} warning${warnings === 1 ? "" : "s"}`;
    summary.dataset.severity = errors > 0 ? "error" : warnings > 0 ? "warning" : "";
    toolbar.setEnabled(true);
    if (Date.now() >= holdStatusUntil) status(`${v.navigator.slideCount} slides - revision ${v.revision}${v.revision === v.saved ? " - saved" : ""}`);
  }

  // --- export PDF ------------------------------------------------------------------------
  // The server prints the saved file, so unsaved edits are saved first. The result stays in the
  // status bar for a while (view updates would otherwise overwrite it at once).
  let exporting = false;
  let holdStatusUntil = 0;
  const say = (message: string): void => { holdStatusUntil = Date.now() + 15000; status(message); };
  button("export-pdf").addEventListener("click", (event) => {
    if (exporting || view === null) return;
    exporting = true;
    button("export-pdf").disabled = true;
    say("Exporting PDF...");
    void (async () => {
      try {
        const dirty = view !== null && view.revision !== view.saved;
        if (dirty) {
          const saved = await enqueue(() => send(requests.command("save", view?.revision)));
          if (!saved.ok) { say(`PDF export failed: could not save first: ${saved.error.message}`); return; }
        }
        say(pdfStatus(await exportPdf((url, init) => fetch(url, init), location.origin, entry, event.shiftKey)));
      } finally {
        exporting = false;
        if (view !== null) chrome(view);
      }
    })();
  });

  const command = (name: string): void => {
    void enqueue(async () => {
      const response = await send(requests.command(name, view?.revision));
      if (!response.ok) status(response.error.message);
    });
  };
  button("undo").addEventListener("click", () => command("undo"));
  button("redo").addEventListener("click", () => command("redo"));
  button("save").addEventListener("click", () => command("save"));
  for (const id of ["new-slide", "deck-add"]) button(id).addEventListener("click", () => command("new_slide"));
  doc.addEventListener("keydown", (event) => {
    if ((event.ctrlKey || event.metaKey) && event.key === "s") { event.preventDefault(); command("save"); }
  });

  const toolbar = installStyleToolbar({
    root: doc, selection: () => doc.getSelection() as never, revision: () => view?.revision ?? null,
    send: async (request) => {
      const response = await enqueue(() => send(request));
      return response.ok ? { ok: true } : { ok: false, message: response.error.message };
    },
    status,
  });

  // --- view toggles & zoom ---------------------------------------------------------------
  const toggle = (id: string, apply: (on: boolean) => void): void => {
    const el = button(id);
    el.addEventListener("click", () => { const on = el.getAttribute("aria-pressed") !== "true"; el.setAttribute("aria-pressed", String(on)); apply(on); });
  };
  toggle("view-source", (on) => { $("workspace").dataset.sourceVisible = String(on); });
  toggle("view-notes", (on) => { $("deck-canvas").dataset.notes = String(on); deck.setShowNotes(on); });
  const camera = installFreeZoom({
    scroller: $("deck"), canvas: $("deck-canvas"),
    onChange: (zoom) => { $("zoom-readout").textContent = `${Math.round(zoom * 100)}%`; },
  });
  $("zoom-in").addEventListener("click", () => camera.zoomBy(zoomStep));
  $("zoom-out").addEventListener("click", () => camera.zoomBy(1 / zoomStep));
  $("zoom-readout").addEventListener("click", () => camera.zoomTo(1));

  // --- presentations sidebar (desktop shell only) ----------------------------------------
  if (window.__SB_SHELL__ !== undefined) {
    let storage: Storage | undefined;
    try { storage = window.localStorage; } catch { /* blocked */ }
    installSidebar({
      doc, shell: window.__SB_SHELL__, root: $("pres-sidebar"), toggle: button("view-presentations"),
      workspace: $("workspace"), onError: status, storage,
    });
  }

  // --- presenting ------------------------------------------------------------------------
  hub = createPresenterHub({
    channel: openChannel(),
    request: (request) => enqueue(() => send(request)),
    navigator: () => view?.navigator.items ?? [],
    title: () => view?.frontmatter.title ?? "",
    onError: status,
  });
  // Present always works: it (re)opens both windows (a closed or stale window comes back)
  // and continues where the show is, or starts at the active slide.
  button("present-btn").addEventListener("click", () => {
    presenting = true;
    windowsOpen = false;
    openWindows();
    const at = hub!.position;
    void (at !== null ? hub!.resume() : hub!.open(view?.navigator.activeFrame ?? undefined));
  });

  // --- connection ------------------------------------------------------------------------
  const conn = $("conn");
  let everOpen = false;
  transport.onState((state) => {
    conn.dataset.state = state;
    conn.textContent = { connecting: "Connecting", open: "Connected", reconnecting: "Reconnecting", closed: "Disconnected" }[state];
    if (state === "open") {
      banner(null);
      // A restarted sb has no presentation: restore it where it was.
      // A reconnect may reach a restarted sb, which has no project open and no presentation:
      // reopen the project (a no-op refresh for a server that kept it), then resume presenting.
      if (everOpen) void enqueue(async () => {
        const snapshot = await send(requests.workspaceSnapshot());
        if (!snapshot.ok) await send(requests.openProject(entry));
      }).then(() => hub?.resume());
      everOpen = true;
    } else if (everOpen) {
      banner("Lost the connection to sb serve. Reconnecting; your edits stay in the source pane.");
    }
  });
  transport.onPush((push) => { void adopt(push); });

  if (fixture) conn.textContent = "Fixture";
  const entry = params.get("entry") ?? (fixture ? "deck.slideBlaster.md" : await discoverEntry());
  const opened = await enqueue(() => send(requests.openProject(entry)));
  if (!opened.ok) {
    status(`Could not open ${entry}: ${opened.error.message}`);
    banner(`Could not open ${entry}: ${opened.error.message}`);
  }
  if (!fixture) {
    const watcher = createCapClient(capUrlFor(location));
    watcher.onEvent((event) => {
      if (event.event === "watch" && themeLoaded !== "" && event.changes.some((c) => c.path.includes("themes/"))) reloadTheme(themeLoaded);
    });
    void watcher.ready().then(() => watcher.subscribeWatch()).catch(() => { /* no live theme reload */ });
  }
  (window as unknown as { sb: unknown }).sb = { transport, pane, deck, view: () => view };
}

main().catch((error) => { status(`Startup failed: ${String(error)}`); banner(`Startup failed: ${String(error)}`); });
