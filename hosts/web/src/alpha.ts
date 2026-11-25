/**
 * Alpha shell: wires the session/1 transport (WebSocket to `sb serve`, or the fixture core
 * with `?fixture=1`) to the CM6 pane, the continuous deck view and the presenter hub.
 * The shell forwards facts and adopts what the core returns; it never parses the deck,
 * mints ids or computes revisions.
 */
import { attachDrawingEdit } from "./ui/drawing-edit.ts";
import { createDomMeasurer, type DomMeasurer } from "./measure.ts";
import { ensureKatexCss } from "./content/katex-css.ts";
import { createShikiHighlighter } from "./content/highlight.ts";
import { katexProvider } from "./content/math.ts";
import { capUrlFor, createCapClient } from "./cap/client.ts";
import { createFakeCore } from "./fixture/fake-core.ts";
import { createCapProjectHost } from "./host/cap-host.ts";
import type { ProjectFile, ProjectHost } from "./host/project-host.ts";
import { createShellProjectHost, type ShellApi } from "./host/shell-host.ts";
import { createPresenterHub, type PresenterHub } from "./presenter/model.ts";
import { createBrowserWindowOpener, openChannel, type WindowOpener } from "./presenter/windows.ts";
import { bytesFromBase16, requests, type Effect, type Request, type SessionResponse, type SessionSuccess, type View } from "./protocol/session.ts";
import { createSourcePane } from "./source/pane.ts";
import { applyThemeCss, loadTheme } from "./theme.ts";
import { createInPageTransport } from "./transport/in-page.ts";
import { createWebSocketTransport, sessionUrlFor, type SessionTransport } from "./transport/transport.ts";
import { createCanvasEdit } from "./ui/canvas-edit.ts";
import { createDeckView } from "./ui/deck-view.ts";
import { exportPdf, pdfStatus } from "./ui/export-pdf.ts";
import { installFreeZoom, zoomStep } from "./ui/free-zoom.ts";
import { currentFolder, installSidebar, resolveDeckFolder, type ShellBridge } from "./ui/sidebar.ts";
import { createShapeLoader } from "./ui/shape-library.ts";
import { installStyleToolbar } from "./ui/style-toolbar.ts";
import { loadSessionCore } from "./wasm/session-core.ts";

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

/**
 * Where the core runs. In the desktop app (and with `?core=page`) it runs in this page and `host`
 * is where the project's files are; otherwise it runs inside `sb serve`, reached over a socket.
 */
interface Wiring {
  readonly transport: SessionTransport;
  readonly host: ProjectHost | null;
  /** The project's files as first listed (in-page core only). */
  readonly files: Promise<readonly ProjectFile[]> | null;
}

/** The themes shipped with the editor, as `themes/<name>/...` project files. */
async function bundledThemes(): Promise<ProjectFile[]> {
  const root = new URL("./dist/themes/", doc.baseURI);
  const manifest = await fetch(new URL("manifest.json", root));
  if (!manifest.ok) return [];
  const names = (await manifest.json()) as unknown;
  if (!Array.isArray(names)) return [];
  const files = await Promise.all(names.filter((n): n is string => typeof n === "string").map(async (name) => {
    const response = await fetch(new URL(name, root));
    return response.ok ? [{ path: `themes/${name}`, bytes: new Uint8Array(await response.arrayBuffer()) }] : [];
  }));
  return files.flat();
}

async function wire(): Promise<Wiring> {
  if (params.get("fixture") === "1") {
    const response = await fetch(new URL("./fixtures/plans/sample-deck.slideBlaster.md", doc.baseURI));
    return { transport: createFakeCore({ source: new Uint8Array(await response.arrayBuffer()), figureDelayMs: 900 }), host: null, files: null };
  }
  const shellInPage = window.__SB_SHELL__?.inPage === true;
  if (!shellInPage && params.get("core") !== "page") return { transport: createWebSocketTransport({ url: sessionUrlFor(location) }), host: null, files: null };
  const tauri = (window as unknown as { __TAURI__?: { core: { invoke: ShellApi["invoke"] }; event: { listen: ShellApi["listen"] } } }).__TAURI__;
  const real = shellInPage && tauri !== undefined
    ? createShellProjectHost({ invoke: (command, args) => tauri.core.invoke(command, args), listen: (event, handler) => tauri.event.listen(event, handler) })
    : createCapProjectHost(createCapClient(capUrlFor(location)), location.origin);
  // The first listing serves both the choice of deck and the core's first open.
  let first: Promise<ProjectFile[]> | null = real.list();
  const files = first;
  const host: ProjectHost = { ...real, list: () => { const listed = first ?? real.list(); first = null; return listed; } };
  const core = await loadSessionCore(doc.baseURI);
  const library = async (path: string): Promise<Uint8Array | null> => {
    const response = await fetch(new URL(`./dist/${path}`, doc.baseURI));
    if (!response.ok) return null;
    const bytes = new Uint8Array(await response.arrayBuffer());
    // an app that answers every unknown path with its start page has no such file
    return decoder.decode(bytes.subarray(0, 4096)).includes("\\tikzset{") ? bytes : null;
  };
  return { transport: createInPageTransport({ core, host, bundledThemes, library }), host, files };
}

/** Which deck the project holds (default, revisitable: first `*.slideBlaster.md`). */
async function discoverEntry(wiring: Wiring): Promise<string> {
  // The project's own decks only (`_up/...` are the files of decks it includes), nearest the root first.
  const depth = (path: string): number => path.split("/").length;
  const first = (paths: readonly string[]): string | undefined =>
    paths.filter((path) => path.endsWith(".slideBlaster.md") && !path.startsWith("_up/")).sort((a, b) => depth(a) - depth(b) || (a < b ? -1 : a > b ? 1 : 0))[0];
  if (wiring.files !== null) return first((await wiring.files.catch(() => [])).map((file) => file.path)) ?? "deck.slideBlaster.md";
  const cap = createCapClient(capUrlFor(location));
  try {
    await cap.ready();
    const files = await cap.listProject("", true);
    return first(files.filter((f) => f.kind === "file").map((f) => f.path)) ?? "deck.slideBlaster.md";
  } catch {
    return "talk.slideBlaster.md";
  } finally {
    cap.close();
  }
}

async function main(): Promise<void> {
  const wiring = await wire();
  const { transport, host } = wiring;
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
  let themeShown: { name: string; css: string } | null = null;
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
    const projectPrefix = `${base}project/`;
    // The deck's folder is the server's `/project/` when there is one, else the host's files.
    const fetcher = async (url: string): Promise<{ ok: boolean; json(): Promise<unknown>; text(): Promise<string> }> => {
      if (host === null || !url.startsWith(projectPrefix)) return fetch(url, { cache: "no-store" });
      const bytes = await host.read(url.slice(projectPrefix.length)).catch(() => null);
      const text = bytes === null ? "" : decoder.decode(bytes);
      return { ok: bytes !== null, json: async () => JSON.parse(text) as unknown, text: async () => text };
    };
    loadTheme(`${projectPrefix}${deckDir}`, name, fetcher)
      .catch(() => loadTheme(`${base}dist/`, name, fetcher))
      .then((theme) => { applyThemeCss(doc, name, theme.css); themeShown = { name, css: theme.css }; measurer.reset(); hub?.refresh(); }, () => { /* built-in minimal theme */ });
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
  // Canvas edits go to the core as one request each; the answer repaints the slide and the
  // source pane together, so the two views never disagree.
  // A picture file opens in this same editor, as its own document, with a way back.
  const openPicture = (file: string): void => {
    void (async () => {
      if (view !== null && view.revision !== view.saved) {
        const saved = await enqueue(() => send(requests.command("save")));
        if (!saved.ok) { status(`Could not save before opening ${file}: ${saved.error.message}`); return; }
      }
      const next = new URLSearchParams(location.search);
      next.set("entry", file);
      next.set("back", entry);
      location.search = next.toString();
    })();
  };
  // Ctrl+click on a \cat{file} line in the source opens that file.
  pane.element.addEventListener("mousedown", (event) => {
    if (!(event.ctrlKey || event.metaKey) || event.button !== 0) return;
    const at = pane.view.posAtCoords({ x: event.clientX, y: event.clientY });
    if (at === null) return;
    const line = pane.view.state.doc.lineAt(at);
    for (const match of line.text.matchAll(/\\cat(?:\[[^\]]*\])?\{([^}]+)\}/g)) {
      const from = line.from + match.index;
      if (at < from || at > from + match[0].length) continue;
      event.preventDefault();
      openPicture(match[1]!.trim());
      return;
    }
  }, true);
  const editing = createCanvasEdit({
    doc, status,
    reveal: (span) => pane.revealBytes(span),
    source: (span) => new TextDecoder().decode(encoder.encode(pane.getText()).slice(span.start, span.end)),
    pictureFiles: () => view?.pictureFiles ?? [],
    shapes: createShapeLoader(new URL("./dist/catalog/catalog-v1.json", doc.baseURI).href),
    open: (file) => openPicture(file),
    write: (span, expected, replacement) => enqueue(async () => {
      if (view === null) return { ok: false as const, message: "No deck is open" };
      const response = await send(requests.applySourceReplace(view.revision, span, encoder.encode(expected), encoder.encode(replacement)));
      return response.ok ? { ok: true as const, created: null } : { ok: false as const, message: response.error.message };
    }),
    edit: (frame, op) => enqueue(async () => {
      if (view === null) return { ok: false as const, message: "No deck is open" };
      const response = await send(requests.pictureEdit(view.revision, frame, op));
      if (!response.ok) return { ok: false as const, message: response.error.message };
      const made = response.effects.find((e) => e.kind === "node_created");
      const all = response.effects.flatMap((e) => e.kind === "node_created" ? [e.node] : []);
      return { ok: true as const, created: made !== undefined && made.kind === "node_created" ? made.node : null, made: all };
    }),
  });
  attachDrawingEdit({
    doc, status, root: $("deck-canvas"),
    edit: (figure, op) => enqueue(async () => {
      if (view === null) return { ok: false as const, message: "No deck is open" };
      const response = await send(requests.figureEdit(view.revision, figure, op));
      return response.ok ? { ok: true as const } : { ok: false as const, message: response.error.message };
    }),
  });
  const deck = createDeckView({
    editing,
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
          const saved = await enqueue(() => send(requests.command("save")));
          if (!saved.ok) { say(`PDF export failed: could not save first: ${saved.error.message}`); return; }
        }
        const steps = !event.shiftKey;
        const result = host !== null ? await host.exportPdf(entry, steps) : await exportPdf((url, init) => fetch(url, init), location.origin, entry, steps);
        say(pdfStatus(result));
        if (result.ok && result.path !== undefined) openWrittenPdf(result.path, result.name);
      } finally {
        exporting = false;
        if (view !== null) chrome(view);
      }
    })();
  });

  const command = (name: string): void => {
    void enqueue(async () => {
      const response = await send(requests.command(name, name === "save" ? undefined : view?.revision));
      if (!response.ok) status(response.error.message);
    });
  };
  button("undo").addEventListener("click", () => command("undo"));
  button("redo").addEventListener("click", () => command("redo"));
  button("save").addEventListener("click", () => command("save"));
  for (const id of ["new-slide", "deck-add"]) button(id).addEventListener("click", () => command("new_slide"));
  doc.addEventListener("keydown", (event) => {
    if (!(event.ctrlKey || event.metaKey)) return;
    if (event.key === "s") { event.preventDefault(); command("save"); return; }
    // Undo and redo for canvas edits; inside the source pane or a text field the field's own undo applies.
    const typing = (event.target as HTMLElement | null)?.closest?.("input, textarea, select, [contenteditable=''], [contenteditable='true'], .cm-editor") != null;
    if (typing) return;
    const key = event.key.toLowerCase();
    if (key === "z" && !event.shiftKey) { event.preventDefault(); command("undo"); }
    else if (key === "y" || (key === "z" && event.shiftKey)) { event.preventDefault(); command("redo"); }
  });

  const toolbar = installStyleToolbar({
    root: doc, selection: () => doc.getSelection() as never, revision: () => view?.revision ?? null,
    send: async (request) => {
      const response = await enqueue(() => send(request));
      return response.ok ? { ok: true } : { ok: false, message: response.error.message };
    },
    status,
  });

  // The written PDF opens in the desktop's PDF viewer; in a browser, in a new tab (served from the project).
  const openWrittenPdf = (path: string, name: string | undefined): void => {
    const shell = window.__SB_SHELL__;
    if (shell?.openPdf !== undefined) { void shell.openPdf(path).catch((e: unknown) => say(`PDF written, but could not open it: ${String(e)}`)); return; }
    const deckDir = entry.includes("/") ? entry.slice(0, entry.lastIndexOf("/") + 1) : "";
    if (name !== undefined) window.open(`${base}project/${deckDir}${encodeURIComponent(name)}`, "_blank");
  };

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
    theme: () => themeShown,
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
  const showState = (state: ReturnType<SessionTransport["state"]>): void => {
    conn.dataset.state = state;
    conn.textContent = { connecting: "Connecting", open: host !== null ? "Ready" : "Connected", reconnecting: "Reconnecting", closed: "Disconnected" }[state];
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
  };
  transport.onState(showState);
  // the in-page core is ready from the start and never announces it
  if (transport.state() === "open") showState("open");
  transport.onPush((push) => { void adopt(push); });

  if (fixture) conn.textContent = "Fixture";
  const entry = params.get("entry") ?? (fixture ? "deck.slideBlaster.md" : await discoverEntry(wiring));
  const opened = await enqueue(() => send(requests.openProject(entry)));
  // Opened from a deck (a picture file brought in with \\cat): offer the way back.
  const backTo = params.get("back");
  if (backTo !== null) {
    const back = doc.createElement("button");
    back.type = "button";
    back.className = "app-back";
    back.textContent = "\u2190 Back to deck";
    back.title = `Save and go back to ${backTo}`;
    back.addEventListener("click", () => {
      void (async () => {
        if (view !== null && view.revision !== view.saved) {
          const saved = await enqueue(() => send(requests.command("save")));
          if (!saved.ok) { status(`Could not save: ${saved.error.message}`); return; }
        }
        const next = new URLSearchParams(location.search);
        next.set("entry", backTo);
        next.delete("back");
        location.search = next.toString();
      })();
    });
    $("view-source").before(back);
  }
  if (!opened.ok) {
    status(`Could not open ${entry}: ${opened.error.message}`);
    banner(`Could not open ${entry}: ${opened.error.message}`);
  }
  if (host !== null) {
    host.onChange((changes) => { if (themeLoaded !== "" && changes.some((c) => c.path.includes("themes/"))) reloadTheme(themeLoaded); });
  } else if (!fixture) {
    const watcher = createCapClient(capUrlFor(location));
    watcher.onEvent((event) => {
      if (event.event === "watch" && themeLoaded !== "" && event.changes.some((c) => c.path.includes("themes/"))) reloadTheme(themeLoaded);
    });
    void watcher.ready().then(() => watcher.subscribeWatch()).catch(() => { /* no live theme reload */ });
  }
  (window as unknown as { sb: unknown }).sb = { transport, pane, deck, view: () => view };
}

main().catch((error) => { status(`Startup failed: ${String(error)}`); banner(`Startup failed: ${String(error)}`); });
