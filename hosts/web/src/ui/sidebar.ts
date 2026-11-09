/**
 * Presentations sidebar. Shown only inside the desktop shell, which injects
 * `window.__SB_SHELL__` (the shell owns the list of known presentations and the switching;
 * this file is just its view). Collapsible with the toggle button or Ctrl+B.
 */

/** A deck some presentation includes (`\include{..}`), nested to any depth. Derived by the shell. */
export interface ShellSub {
  path: string;
  title: string;
  current: boolean;
  children: ShellSub[];
}

export interface ShellPresentation {
  path: string;
  title: string;
  lastOpened: number;
  current: boolean;
  /** Included sub-presentations; absent from an older shell. */
  children?: ShellSub[];
}

export interface ShellBridge {
  listPresentations(): Promise<ShellPresentation[]>;
  openPresentation(path: string): Promise<void>;
  addPresentation(): Promise<void>;
  removePresentation(path: string): Promise<ShellPresentation[]>;
}

/** Name for a row: the title the shell supplied, else the last path segment. */
export function presentationLabel(p: Pick<ShellPresentation, "path" | "title">): string {
  const title = p.title.trim();
  if (title !== "") return title;
  const segments = p.path.split(/[\\/]+/).filter((s) => s !== "");
  return segments[segments.length - 1] ?? p.path;
}

/**
 * The folder holding an included deck, from the including deck's folder and the deck file
 * path the session reports (`../other/talk.slideBlaster.md`): `/d/parent` + that = `/d/other`.
 */
export function resolveDeckFolder(base: string, deckPath: string): string {
  const sep = base.includes("\\") && !base.includes("/") ? "\\" : "/";
  const root = /^[\\/]/.test(base) ? sep : "";
  const parts = base.split(/[\\/]+/).filter((x) => x !== "");
  const rel = deckPath.split(/[\\/]+/).filter((x) => x !== "");
  if (/\.slideBlaster\.md$/.test(rel[rel.length - 1] ?? "")) rel.pop();
  for (const seg of rel) {
    if (seg === "." ) continue;
    if (seg === "..") { if (parts.length > 0 && !/^[A-Za-z]:$/.test(parts[parts.length - 1]!)) parts.pop(); } else parts.push(seg);
  }
  return root + parts.join(sep);
}

/** The shell's current presentation folder (top level or nested), if any. */
export function currentFolder(items: readonly ShellPresentation[]): string | null {
  const walk = (subs: readonly ShellSub[]): string | null => {
    for (const s of subs) { if (s.current) return s.path; const inner = walk(s.children); if (inner !== null) return inner; }
    return null;
  };
  for (const p of items) { if (p.current) return p.path; const inner = walk(p.children ?? []); if (inner !== null) return inner; }
  return null;
}

export interface SidebarOptions {
  doc: Document;
  shell: ShellBridge;
  root: HTMLElement;
  toggle: HTMLButtonElement;
  workspace: HTMLElement;
  onError: (message: string) => void;
  storage?: Pick<Storage, "getItem" | "setItem">;
}

const KEY = "sb.presentations.collapsed";

export function installSidebar(o: SidebarOptions): { refresh(): Promise<void>; setCollapsed(on: boolean): void } {
  const { doc, shell, root, toggle, workspace } = o;
  const list = doc.createElement("ul");
  list.className = "pres-list";
  const head = doc.createElement("div");
  head.className = "pres-head";
  const heading = doc.createElement("span");
  heading.textContent = "Presentations";
  const add = doc.createElement("button");
  add.type = "button";
  add.className = "pres-add";
  add.textContent = "+";
  add.title = "Add a presentation folder";
  add.setAttribute("aria-label", "Add a presentation folder");
  head.append(heading, add);
  root.append(head, list);

  const fail = (e: unknown): void => o.onError(e instanceof Error ? e.message : String(e));

  /** Included sub-presentations, indented and smaller; clicking one switches to that deck. */
  const renderSubs = (subs: ShellSub[], depth: number): HTMLElement => {
    const ul = doc.createElement("ul");
    ul.className = "pres-sub";
    for (const sub of subs) {
      const li = doc.createElement("li");
      li.className = "pres-sub-item";
      li.dataset.current = String(sub.current);
      li.dataset.depth = String(depth);
      const open = doc.createElement("button");
      open.type = "button";
      open.className = "pres-open pres-sub-open";
      open.title = sub.path;
      open.textContent = presentationLabel(sub);
      if (sub.current) open.setAttribute("aria-current", "true");
      open.addEventListener("click", () => { if (!sub.current) shell.openPresentation(sub.path).catch(fail); });
      li.append(open);
      if (sub.children.length > 0) li.append(renderSubs(sub.children, depth + 1));
      ul.append(li);
    }
    return ul;
  };

  const render = (items: ShellPresentation[]): void => {
    list.replaceChildren();
    if (items.length === 0) {
      const empty = doc.createElement("li");
      empty.className = "pres-empty";
      empty.textContent = "No presentations yet";
      list.append(empty);
    }
    for (const p of items) {
      const li = doc.createElement("li");
      li.className = "pres-item";
      li.dataset.current = String(p.current);
      const open = doc.createElement("button");
      open.type = "button";
      open.className = "pres-open";
      open.title = p.path;
      open.textContent = presentationLabel(p);
      if (p.current) open.setAttribute("aria-current", "true");
      open.addEventListener("click", () => { if (!p.current) shell.openPresentation(p.path).catch(fail); });
      const remove = doc.createElement("button");
      remove.type = "button";
      remove.className = "pres-remove";
      remove.textContent = "×";
      remove.title = "Remove from this list (the folder is not deleted)";
      remove.setAttribute("aria-label", `Remove ${presentationLabel(p)} from the list`);
      remove.addEventListener("click", () => { shell.removePresentation(p.path).then(render, fail); });
      li.append(open, remove);
      if (p.children !== undefined && p.children.length > 0) li.append(renderSubs(p.children, 1));
      list.append(li);
    }
  };

  const refresh = (): Promise<void> => shell.listPresentations().then(render, fail);
  add.addEventListener("click", () => { shell.addPresentation().catch(fail); });

  const setCollapsed = (on: boolean): void => {
    workspace.dataset.presentations = on ? "collapsed" : "open";
    toggle.setAttribute("aria-pressed", String(!on));
    try { o.storage?.setItem(KEY, on ? "1" : "0"); } catch { /* per-viewer convenience only */ }
  };

  root.hidden = false;
  toggle.hidden = false;
  let stored = false;
  try { stored = o.storage?.getItem(KEY) === "1"; } catch { /* default open */ }
  setCollapsed(stored);
  toggle.addEventListener("click", () => setCollapsed(workspace.dataset.presentations !== "collapsed"));
  doc.addEventListener("keydown", (event) => {
    if ((event.ctrlKey || event.metaKey) && !event.shiftKey && !event.altKey && event.key.toLowerCase() === "b") {
      event.preventDefault();
      setCollapsed(workspace.dataset.presentations !== "collapsed");
    }
  });
  void refresh();
  return { refresh, setCollapsed };
}
