/**
 * Editing a TikZ figure the core draws itself (a `drawing` in a slide's content).
 *
 * The page only points and asks. A press selects a node or a line (with Shift, one more),
 * a drag moves what is selected, a double click retypes a node's text or, on empty ground,
 * makes a new node there; Delete takes the selection out. A selected node has a handle to
 * resize it and one to draw a line to another node; the bar sets fill and line colour and
 * how a line goes. What each of these means for the figure's text is decided by the core
 * (`figure_edit`), which rewrites the statements in question and sends the new plan back.
 */
import type { FigureOp } from "../protocol/session.ts";

export interface DrawingEditOptions {
  readonly doc: Document;
  /** The element the slides are painted in; only drawings inside it are edited. */
  readonly root: HTMLElement;
  readonly status: (message: string) => void;
  readonly edit: (figure: string, op: FigureOp) => Promise<{ ok: true } | { ok: false; message: string }>;
}

interface Part { readonly at: number; readonly node: boolean }
interface Picked { readonly figure: string; readonly parts: readonly Part[] }

/** The fills and lines the bar offers, as xcolor writes them; an empty value takes the option away. */
export const drawingFills: readonly (readonly [string, string, string])[] = [
  ["none", "none", "transparent"], ["white", "white", "#ffffff"], ["blue", "blue!12", "#e0e0ff"], ["green", "green!15", "#d9ffd9"],
  ["orange", "orange!20", "#ffe5cc"], ["red", "red!15", "#ffd9d9"], ["yellow", "yellow!35", "#ffffa6"], ["grey", "black!12", "#e0e0e0"],
];
export const drawingLines: readonly (readonly [string, string, string])[] = [
  ["none", "none", "transparent"], ["black", "black", "#000000"], ["grey", "black!50", "#808080"], ["blue", "blue!70!black", "#0000b3"],
  ["red", "red!75!black", "#bf0000"], ["green", "green!55!black", "#008c00"],
];

/** A drag on the page as a move in the figure: centimetres, right and up. */
export function dragInFigure(dx: number, dy: number, shownWidth: number, planWidth: number, pixelsPerCm: number): { dx: number; dy: number } {
  const shown = shownWidth / planWidth;
  const round = (v: number): number => Math.round((v / shown / pixelsPerCm) * 20) / 20 || 0;
  return { dx: round(dx), dy: round(-dy) };
}

/** How a line can go, as the bar offers it: the route's name for the core, the button's face and its title. */
export const drawingRoutes: readonly (readonly [string, string, string])[] = [
  ["straight", "╱", "Straight"], ["hv", "┐", "Across, then down or up"], ["vh", "└", "Down or up, then across"],
  ["bend left", "⌒", "Bent to the left"], ["bend right", "⌣", "Bent to the right"],
];

/** A place on the page as a place in the picture: centimetres, y up, as the core counts. */
export function pointInFigure(x: number, y: number, shown: { left: number; top: number; width: number }, planWidth: number, pixelsPerCm: number, origin: { x: number; y: number }): { x: number; y: number } {
  const perCm = (shown.width / planWidth) * pixelsPerCm;
  const round = (v: number): number => Math.round(v * 20) / 20 || 0;
  return { x: round(origin.x + (x - shown.left) / perCm), y: round(origin.y - (y - shown.top) / perCm) };
}

/** A node pulled out from its centre to a corner at the pointer: its new size in centimetres, never less than a few millimetres. */
export function sizeFromCorner(centre: { x: number; y: number }, pointer: { x: number; y: number }, shownWidth: number, planWidth: number, pixelsPerCm: number): { width: number; height: number } {
  const perCm = (shownWidth / planWidth) * pixelsPerCm;
  const round = (v: number): number => Math.max(0.3, Math.round((v / perCm) * 20) / 20);
  return { width: round(2 * Math.abs(pointer.x - centre.x)), height: round(2 * Math.abs(pointer.y - centre.y)) };
}

export function attachDrawingEdit(options: DrawingEditOptions): { dispose(): void } {
  const { doc, root, status } = options;
  let picked: Picked | null = null;
  let chrome: HTMLElement[] = [];
  let typing = false;
  let busy = false;
  let typeNewest: string | null = null;
  let settle: ReturnType<typeof setTimeout> | null = null;
  let ground: { time: number; x: number; y: number; figure: string; shown: DOMRect; planWidth: number; scale: number; origin: { x: number; y: number } } | null = null;

  const drawingOf = (target: EventTarget | null): HTMLElement | null =>
    target instanceof Element && root.contains(target) ? target.closest<HTMLElement>(".sb-drawing") : null;
  const partOf = (target: EventTarget | null): Element | null =>
    target instanceof Element ? target.closest("[data-drawing-at]") : null;
  const drawingFor = (figure: string): HTMLElement | null =>
    [...root.querySelectorAll<HTMLElement>(".sb-drawing")].find((d) => d.dataset.figure === figure) ?? null;
  const elementsOf = (drawing: HTMLElement, at: number): Element[] => [...drawing.querySelectorAll(`[data-drawing-at="${at}"]`)];
  const measures = (drawing: HTMLElement) => ({
    planWidth: Number(drawing.dataset.planWidth), scale: Number(drawing.dataset.scale),
    origin: { x: Number(drawing.dataset.originX), y: Number(drawing.dataset.originY) },
  });

  function clear(): void {
    for (const el of chrome) el.remove();
    chrome = [];
    for (const el of root.querySelectorAll(".sb-drawing-picked")) el.classList.remove("sb-drawing-picked");
  }

  async function send(figure: string, op: FigureOp): Promise<boolean> {
    const result = await options.edit(figure, op);

    if (!result.ok) status(result.message);
    return result.ok;
  }
  const each = (make: (part: Part) => FigureOp): FigureOp | null => {
    if (picked === null || picked.parts.length === 0) return null;
    const ops = picked.parts.map(make);
    return ops.length === 1 ? ops[0]! : { kind: "batch", ops };
  };

  function button(label: string, title: string, act: () => void): HTMLButtonElement {
    const made = doc.createElement("button");
    made.type = "button";
    made.className = "sb-style-button";
    made.title = title;
    made.textContent = label;
    made.addEventListener("click", act);
    return made;
  }
  function group(label: string): HTMLElement {
    const made = doc.createElement("span");
    made.className = "sb-style-group";
    const name = doc.createElement("span");
    name.className = "sb-style-label";
    name.textContent = label;
    made.append(name);
    return made;
  }
  function swatches(label: string, key: string, all: readonly (readonly [string, string, string])[]): HTMLElement {
    const made = group(label);
    for (const [title, value, shown] of all) {
      const swatch = button(value === "none" ? "∅" : "", `${label}: ${title}`, () => {
        const op = each((part) => ({ kind: "option", at: part.at, key, value }));
        if (op !== null && picked !== null) void send(picked.figure, op);
      });
      swatch.classList.add("sb-drawing-swatch");
      swatch.style.background = shown;
      made.append(swatch);
    }
    return made;
  }
  function fixed(el: HTMLElement, x: number, y: number): void {
    el.style.position = "fixed";
    el.style.left = `${x}px`;
    el.style.top = `${y}px`;
    doc.body.append(el);
    chrome.push(el);
  }

  function show(): void {
    clear();
    if (picked === null) return;
    const drawing = drawingFor(picked.figure);
    const present = drawing === null ? [] : picked.parts.filter((part) => elementsOf(drawing, part.at).length > 0);
    if (drawing === null || present.length === 0) { picked = null; return; }
    picked = { figure: picked.figure, parts: present };
    const elements = present.flatMap((part) => elementsOf(drawing, part.at));
    for (const el of elements) el.classList.add("sb-drawing-picked");
    const boxes = elements.map((el) => el.getBoundingClientRect());
    const left = Math.min(...boxes.map((b) => b.left)), right = Math.max(...boxes.map((b) => b.right)), top = Math.min(...boxes.map((b) => b.top)), bottom = Math.max(...boxes.map((b) => b.bottom));
    const bar = doc.createElement("div");
    bar.className = "sb-style-bar sb-drawing-bar";
    const allNodes = present.every((part) => part.node);
    const allLines = present.every((part) => !part.node);
    if (allNodes) bar.append(swatches("Fill", "fill", drawingFills));
    bar.append(swatches("Line", "draw", drawingLines));
    if (allLines) {
      const routes = group("Route");
      for (const [route, face, title] of drawingRoutes) {
        routes.append(button(face, title, () => { const op = each((part) => ({ kind: "route", at: part.at, to: route as "straight" })); if (op !== null && picked !== null) void send(picked.figure, op); }));
      }
      bar.append(routes);
    }
    bar.append(button("Delete", "Delete", remove));
    // on the page itself, so no slide cuts it off; kept inside the window
    fixed(bar, 0, 0);
    const size = bar.getBoundingClientRect();
    const view = doc.documentElement.getBoundingClientRect();
    bar.style.left = `${Math.max(size.width / 2 + 6, Math.min(view.width - size.width / 2 - 6, (left + right) / 2))}px`;
    if (top - size.height - 14 < 50) { bar.dataset.side = "below"; bar.style.top = `${bottom + 14}px`; }
    else bar.style.top = `${top - 14}px`;
    if (present.length === 1 && present[0]!.node) {
      const resize = doc.createElement("div");
      resize.className = "sb-drawing-handle sb-drawing-resize";
      resize.title = "Drag to resize";
      fixed(resize, right, bottom);
      resize.addEventListener("pointerdown", (event) => startResize(event, drawing, present[0]!, { x: (left + right) / 2, y: (top + bottom) / 2 }));
      const link = doc.createElement("div");
      link.className = "sb-drawing-handle sb-drawing-link";
      link.title = "Drag to another node to draw a line";
      link.textContent = "→";
      fixed(link, right + 14, (top + bottom) / 2);
      link.addEventListener("pointerdown", (event) => startLink(event, drawing, present[0]!, { x: (left + right) / 2, y: (top + bottom) / 2 }));
    }
  }

  function remove(): void {
    const op = each((part) => ({ kind: "delete", at: part.at }));
    if (op === null || picked === null) return;
    const figure = picked.figure;
    picked = null;
    clear();
    void send(figure, op);
  }

  function track(onMove: (event: PointerEvent) => void, onUp: (event: PointerEvent) => void): void {
    const up = (event: PointerEvent): void => {
      doc.removeEventListener("pointermove", onMove, true);
      doc.removeEventListener("pointerup", up, true);
      busy = false;
      onUp(event);
    };
    busy = true;
    doc.addEventListener("pointermove", onMove, true);
    doc.addEventListener("pointerup", up, true);
  }

  function startResize(event: PointerEvent, drawing: HTMLElement, part: Part, centre: { x: number; y: number }): void {
    event.preventDefault();
    event.stopPropagation();
    const ghost = doc.createElement("div");
    ghost.className = "sb-drawing-ghost";
    fixed(ghost, 0, 0);
    const shownWidth = drawing.getBoundingClientRect().width;
    const { planWidth, scale } = measures(drawing);
    const place = (x: number, y: number): void => {
      const w = 2 * Math.abs(x - centre.x), h = 2 * Math.abs(y - centre.y);
      ghost.style.left = `${centre.x - w / 2}px`; ghost.style.top = `${centre.y - h / 2}px`;
      ghost.style.width = `${w}px`; ghost.style.height = `${h}px`;
    };
    place(event.clientX, event.clientY);
    track((move) => place(move.clientX, move.clientY), (up) => {
      const size = sizeFromCorner(centre, { x: up.clientX, y: up.clientY }, shownWidth, planWidth, scale);
      void send(drawing.dataset.figure ?? "", { kind: "resize", at: part.at, ...size }).then(show);
    });
  }

  function startLink(event: PointerEvent, drawing: HTMLElement, part: Part, centre: { x: number; y: number }): void {
    event.preventDefault();
    event.stopPropagation();
    const rubber = doc.createElement("div");
    rubber.className = "sb-drawing-rubber";
    fixed(rubber, centre.x, centre.y);
    const stretch = (x: number, y: number): void => {
      rubber.style.width = `${Math.hypot(x - centre.x, y - centre.y)}px`;
      rubber.style.transform = `rotate(${Math.atan2(y - centre.y, x - centre.x)}rad)`;
    };
    track((move) => stretch(move.clientX, move.clientY), (up) => {
      rubber.remove();
      // what lies under the pointer, the rubber line and the handles aside
      const under = doc.elementsFromPoint(up.clientX, up.clientY).find((el) => el.matches("[data-drawing-node='1']") || el.closest("[data-drawing-node='1']") !== null);
      const target = under?.closest("[data-drawing-node='1']") ?? null;
      if (target === null || drawingOf(target) !== drawing) { show(); return; }
      void send(drawing.dataset.figure ?? "", { kind: "add_line", from: part.at, to: Number(target.getAttribute("data-drawing-at")), options: "->" });
    });
  }

  function retype(part: HTMLElement, figure: string, at: number): void {
    const text = part.querySelector<HTMLElement>(".sb-drawing-text");
    if (text === null) return;
    clear();
    typing = true;
    const before = part.dataset.source ?? "";
    const painted = [...text.childNodes];
    text.textContent = before;
    text.contentEditable = "plaintext-only";
    text.classList.add("sb-drawing-typing");
    text.focus();
    doc.getSelection()?.selectAllChildren(text);
    let done = false;
    const finish = (keep: boolean): void => {
      if (done) return;
      done = true;
      typing = false;
      const typed = (text.textContent ?? "").replace(/\n+$/, "");
      text.contentEditable = "false";
      text.classList.remove("sb-drawing-typing");
      if (keep && typed !== before) void send(figure, { kind: "text", at, text: typed });
      else text.replaceChildren(...painted);
    };
    text.addEventListener("blur", () => finish(true), { once: true });
    text.addEventListener("keydown", (event) => {
      event.stopPropagation();
      if (event.key === "Escape") { event.preventDefault(); finish(false); text.blur(); }
      if (event.key === "Enter" && !event.shiftKey) { event.preventDefault(); finish(true); text.blur(); }
    });
  }

  const onDown = (event: PointerEvent): void => {
    if (typing || busy || event.button !== 0) return;
    if (event.target instanceof Element && event.target.closest(".sb-drawing-bar, .sb-drawing-handle")) return;
    const drawing = drawingOf(event.target);
    const part = drawing === null ? null : partOf(event.target);
    // a second press on the same empty spot of a figure makes a node there. It is told from the first
    // press's own measures: a press on a slide repaints it, so the figure pressed first may be gone by now.
    if (part === null && ground !== null && event.timeStamp - ground.time < 450 && Math.hypot(event.clientX - ground.x, event.clientY - ground.y) < 6) {
      const first = ground;
      ground = null;
      event.preventDefault();
      event.stopPropagation();
      const at = pointInFigure(first.x, first.y, first.shown, first.planWidth, first.scale, first.origin);
      typeNewest = first.figure;
      void send(first.figure, { kind: "add_node", x: at.x, y: at.y, options: "draw", text: "text" }).then((ok) => { if (!ok) typeNewest = null; });
      return;
    }
    ground = drawing !== null && part === null ? { time: event.timeStamp, x: event.clientX, y: event.clientY, figure: drawing.dataset.figure ?? "", shown: drawing.getBoundingClientRect(), ...measures(drawing) } : null;
    if (drawing === null || part === null) { if (picked !== null) { picked = null; clear(); } return; }
    event.preventDefault();
    event.stopPropagation();
    const figure = drawing.dataset.figure ?? "";
    const pressed: Part = { at: Number(part.getAttribute("data-drawing-at")), node: part.getAttribute("data-drawing-node") === "1" };
    const had = picked !== null && picked.figure === figure ? picked.parts : [];
    const inside = had.some((one) => one.at === pressed.at);
    if (event.shiftKey || event.ctrlKey || event.metaKey) picked = { figure, parts: inside ? had.filter((one) => one.at !== pressed.at) : [...had, pressed] };
    else if (!inside) picked = { figure, parts: [pressed] };
    show();
    if (picked === null) return;
    const moving = picked.parts;
    const elements = moving.flatMap((one) => elementsOf(drawing, one.at));
    const start = { x: event.clientX, y: event.clientY };
    let moved = false;
    const shownWidth = drawing.getBoundingClientRect().width;
    const { planWidth, scale } = measures(drawing);
    const settle = (): void => { for (const el of elements) { (el as HTMLElement | SVGElement).style.transform = ""; (el as HTMLElement).style.translate = ""; } };
    track((move) => {
      const dx = move.clientX - start.x, dy = move.clientY - start.y;
      if (!moved && Math.hypot(dx, dy) < 4) return;
      if (!moved) { moved = true; for (const el of chrome) el.remove(); chrome = []; }
      // paths live in the drawing's own coordinates, nodes in the page's
      for (const el of elements) {
        if (el instanceof SVGElement) el.style.transform = `translate(${(dx * planWidth) / shownWidth}px, ${(dy * planWidth) / shownWidth}px)`;
        else (el as HTMLElement).style.translate = `${dx}px ${dy}px`;
      }
    }, (up) => {
      if (!moved) { if (!event.shiftKey && inside && had.length > 1) { picked = { figure, parts: [pressed] }; show(); } return; }
      const by = dragInFigure(up.clientX - start.x, up.clientY - start.y, shownWidth, planWidth, scale);
      if (by.dx === 0 && by.dy === 0) { settle(); show(); return; }
      const ops: FigureOp[] = moving.map((one) => ({ kind: "move", at: one.at, dx: by.dx, dy: by.dy }));
      void send(figure, ops.length === 1 ? ops[0]! : { kind: "batch", ops }).then((ok) => { if (!ok) { settle(); show(); } });
    });
  };
  const onDouble = (rawEvent: MouseEvent): void => {
    // the first click may have repainted the slide: then what was clicked is gone, and what is there now is asked
    const live = rawEvent.target instanceof Node && rawEvent.target.isConnected ? rawEvent.target : doc.elementFromPoint(rawEvent.clientX, rawEvent.clientY);
    const event = { target: live, clientX: rawEvent.clientX, clientY: rawEvent.clientY, preventDefault: () => rawEvent.preventDefault(), stopPropagation: () => rawEvent.stopPropagation() };
    const drawing = drawingOf(event.target);
    if (drawing === null || typing) return;
    if (event.target instanceof Element && event.target.closest(".sb-drawing-bar, .sb-drawing-handle")) return;
    event.preventDefault();
    event.stopPropagation();
    const figure = drawing.dataset.figure ?? "";
    const part = partOf(event.target);
    if (part === null) return;
    const at = Number(part.getAttribute("data-drawing-at"));
    const node = elementsOf(drawing, at).find((el): el is HTMLElement => el instanceof HTMLElement && el.classList.contains("sb-drawing-node"));
    if (node !== undefined) retype(node, figure, at);
  };
  const onKey = (event: KeyboardEvent): void => {
    if (typing || picked === null) return;
    const active = doc.activeElement;
    if (active instanceof HTMLElement && (active.isContentEditable || active.tagName === "INPUT" || active.tagName === "TEXTAREA")) return;
    if (event.key === "Delete" || event.key === "Backspace") { event.preventDefault(); event.stopPropagation(); remove(); }
    else if (event.key === "Escape") { picked = null; clear(); }
  };
  const onScroll = (): void => { if (chrome.length > 0 && !busy) show(); };
  // a new plan replaces the painted figure: what was picked is marked again, and a node just made is typed in
  const observer = new MutationObserver(() => {
    if (typing || busy) return;
    if (typeNewest !== null) {
      // the page paints a new node twice (as estimated, then as measured): typing starts once it has settled
      if (settle !== null) clearTimeout(settle);
      settle = setTimeout(() => {
        settle = null;
        if (typeNewest === null || typing || busy) return;
        const figure = typeNewest;
        const drawing = drawingFor(figure);
        const nodes = drawing === null ? [] : [...drawing.querySelectorAll<HTMLElement>(".sb-drawing-node")];
        const newest = nodes.sort((a, b) => Number(b.getAttribute("data-drawing-at")) - Number(a.getAttribute("data-drawing-at")))[0];
        if (newest === undefined || newest.dataset.source !== "text") return;
        typeNewest = null;
        picked = { figure, parts: [{ at: Number(newest.getAttribute("data-drawing-at")), node: true }] };
        retype(newest, figure, Number(newest.getAttribute("data-drawing-at")));
      }, 350);
      return;
    }
    if (picked !== null && root.querySelector(".sb-drawing-picked") === null) show();
  });
  observer.observe(root, { childList: true, subtree: true });
  doc.addEventListener("scroll", onScroll, true);
  doc.addEventListener("pointerdown", onDown, true);
  doc.addEventListener("dblclick", onDouble, true);
  doc.addEventListener("keydown", onKey, true);
  return {
    dispose() {
      observer.disconnect();
      doc.removeEventListener("scroll", onScroll, true);
      doc.removeEventListener("pointerdown", onDown, true);
      doc.removeEventListener("dblclick", onDouble, true);
      doc.removeEventListener("keydown", onKey, true);
      clear();
    },
  };
}
