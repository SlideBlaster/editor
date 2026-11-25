/**
 * Canvas editing of a slide's picture tier: create, select (one or many), drag, turn, flip,
 * line up, reorder, copy and paste, connect, retype, delete.
 *
 * The page only gathers the gesture and previews it; what the gesture means for the source
 * is decided and verified by the core (`picture_edit`). Every accepted edit comes back as a
 * new plan, which repaints the slide and re-attaches this layer, so nothing here is a model:
 * the only state kept across repaints is what is selected and which node is being typed in.
 */
import { trailData, trailPoints, type AttachSide, type Box, type PictureFrom, type PictureLabel, type PictureLine, type PictureNode, type PictureOption, type Plan, type WrittenText } from "../protocol/plan.ts";
import type { PictureOp } from "../protocol/session.ts";
import { shapeThumbnail, type Shape, type ShapeLibrary } from "./shape-library.ts";

const svgNamespace = "http://www.w3.org/2000/svg";

export type EditResult =
  | { readonly ok: true; readonly created: string | null; /** Every node the edit made (a paste makes several). */ readonly made?: readonly string[] }
  | { readonly ok: false; readonly message: string };

export interface CanvasEditOptions {
  readonly doc: Document;
  /** Send one edit of a slide; resolves after the returned view has been painted. */
  readonly edit: (frame: string, op: PictureOp) => Promise<EditResult>;
  /** Replace a piece of the slide's own text: `expected` is what the span holds now. */
  readonly write?: (span: { start: number; end: number }, expected: string, replacement: string) => Promise<EditResult>;
  /** Open a picture file brought in with `\\cat` (double-click or Ctrl+click on it). */
  readonly open?: (file: string) => void;
  /** The project's picture files, offered in the creation menu. */
  readonly pictureFiles?: () => readonly string[];
  /** The shape library, loaded on first use; offered in the creation menu and its "All shapes" panel. */
  readonly shapes?: () => Promise<ShapeLibrary>;
  /** The source text of a span of the open document (what a copy takes). */
  readonly source?: (span: { start: number; end: number }) => string | null;
  /** Show the source of a node or line (Ctrl+click). */
  readonly reveal?: (span: { start: number; end: number }) => void;
  readonly status: (message: string) => void;
}

export interface CanvasEdit {
  /** Make one painted slide editable; returns the detach function. */
  attach(slide: HTMLElement, plan: Plan): () => void;
  destroy(): void;
}

/** What the creation menu offers: a name to filter by, the node's TikZ options and its first text. */
export interface Preset { readonly label: string; readonly hint: string; readonly options: string; readonly text: string;
  /** Not a picture node: start the slide's own body text. */ readonly body?: true;
  /** Not a picture node: bring this picture file in. */ readonly include?: string;
  /** A library shape: `options` is its style name, and the row shows its drawing. */ readonly shape?: Shape;
  /** Not an element: open the panel with every library shape. */ readonly browse?: true }

/** How many library shapes the creation menu itself lists; the panel shows the rest. */
export const menuShapeLimit = 6;
/** How many shapes the panel draws at once. */
export const panelShapeLimit = 240;

export const shapePreset = (shape: Shape): Preset => ({ label: shape.label, hint: shape.category, options: shape.id, text: "", shape });

/** Offered on a slide that has no body text yet. */
export const slideTextPreset: Preset = { label: "Slide text", hint: "ordinary text under the title", options: "", text: "", body: true };

/** What a text edit writes: the typed text, wrapped in its separators when it starts a new body. */
export function writtenReplacement(written: Pick<WrittenText, "part" | "source" | "before" | "after">, typed: string): string | null {
  const text = written.part === "title" ? typed.replace(/\s*\n\s*/g, " ").trim() : typed.replace(/\s+$/, "");
  if (text === written.source) return null;
  if (written.part === "title" && text === "") return null;
  return written.source === "" ? written.before + text + written.after : text;
}

export const presets: readonly Preset[] = [
  { label: "Box", hint: "a framed box", options: "draw", text: "Box" },
  { label: "Text", hint: "plain text", options: "", text: "Text" },
  { label: "Note", hint: "a yellow note", options: "draw, fill=yellow!30", text: "Note" },
  { label: "Accent box", hint: "a blue filled box", options: "draw=blue, fill=blue!10", text: "Box" },
];

/** Presets whose label contains every typed word, best first (a prefix match wins). */
export function filterPresets(query: string, all: readonly Preset[] = presets): Preset[] {
  const words = query.toLowerCase().split(/\s+/).filter((w) => w !== "");
  const hits = all.filter((p) => words.every((w) => p.label.toLowerCase().includes(w)));
  const first = words[0];
  return first === undefined ? hits : [...hits].sort((a, b) => Number(b.label.toLowerCase().startsWith(first)) - Number(a.label.toLowerCase().startsWith(first)));
}

/** Round a plan coordinate to a grid step, so written coordinates stay short. */
export const toGrid = (value: number, step: number): number => Math.round(value / step) * step;

/**
 * Snap a dragged box centre to the centres of the other boxes: within `reach` plan pixels on an
 * axis the centre takes the other's coordinate. Returns the adjusted delta and the guides to draw.
 */
export function snapDelta(
  centre: { x: number; y: number }, delta: { x: number; y: number },
  others: readonly { x: number; y: number }[], reach: number,
): { dx: number; dy: number; guideX: number | null; guideY: number | null } {
  let dx = delta.x, dy = delta.y;
  let guideX: number | null = null, guideY: number | null = null;
  let bestX = reach, bestY = reach;
  for (const o of others) {
    const offX = Math.abs(centre.x + delta.x - o.x);
    if (offX < bestX) { bestX = offX; dx = o.x - centre.x; guideX = o.x; }
    const offY = Math.abs(centre.y + delta.y - o.y);
    if (offY < bestY) { bestY = offY; dy = o.y - centre.y; guideY = o.y; }
  }
  return { dx, dy, guideX, guideY };
}

export interface Slot { readonly to: string; readonly side: AttachSide; readonly distance: number | null; readonly dx: number; readonly dy: number; readonly x: number; readonly y: number }

/** Which way a side points in plan pixels (y down). */
export const sideVector: Readonly<Record<AttachSide, readonly [number, number]>> = {
  "above": [0, -1], "below": [0, 1], "left": [-1, 0], "right": [1, 0],
  "above left": [-1, -1], "above right": [1, -1], "below left": [-1, 1], "below right": [1, 1],
};

/** The centre a box takes when attached on `side` of `other`, `gap` away. */
export function attachedCentre(box: Box, other: Box, side: AttachSide, gap: number): { x: number; y: number } {
  const [sx, sy] = sideVector[side];
  return {
    x: other.x + other.width / 2 + sx * (other.width / 2 + gap + box.width / 2),
    y: other.y + other.height / 2 + sy * (other.height / 2 + gap + box.height / 2),
  };
}

export interface Target { readonly id: string; readonly box: Box; /** The sides on offer; all eight when absent. */ readonly sides?: readonly AttachSide[] }

/**
 * Where you drop decides: each other box offers a place on each of its sides (`distance`
 * away). A dragged box whose centre comes within `reach` of one takes that place and will be
 * attached there; the result carries the delta that puts it exactly on it. A box that is
 * already attached (`current`) can also slide along its side to change the gap: it stays
 * attached while it is within `reach` of that axis, and gets the gap it was dropped at.
 */
export function attachSlot(
  box: Box, delta: { x: number; y: number }, others: readonly Target[], distance: number, reach: number,
  current: { readonly to: string; readonly side: AttachSide } | null = null,
): Slot | null {
  const centre = { x: box.x + box.width / 2, y: box.y + box.height / 2 };
  const now = { x: centre.x + delta.x, y: centre.y + delta.y };
  let best: Slot | null = null;
  let bestOff = reach;
  for (const other of others) {
    for (const side of other.sides ?? (Object.keys(sideVector) as AttachSide[])) {
      const place = attachedCentre(box, other.box, side, distance);
      const off = Math.hypot(now.x - place.x, now.y - place.y);
      if (off < bestOff) { bestOff = off; best = { to: other.id, side, distance: null, dx: place.x - centre.x, dy: place.y - centre.y, x: place.x, y: place.y }; }
    }
  }
  if (best !== null || current === null) return best;
  // sliding: project the drop onto the side's axis and read the gap off it
  const other = others.find((o) => o.id === current.to);
  if (other === undefined) return null;
  const [sx, sy] = sideVector[current.side];
  const zero = attachedCentre(box, other.box, current.side, 0);
  const along = sx !== 0 && sy !== 0 ? Math.min((now.x - zero.x) * sx, (now.y - zero.y) * sy) : (now.x - zero.x) * sx + (now.y - zero.y) * sy;
  const gap = Math.round(along / 4) * 4;
  const place = attachedCentre(box, other.box, current.side, gap);
  if (gap < 8 || gap > 640 || Math.hypot(now.x - place.x, now.y - place.y) > reach) return null;
  return { to: other.id, side: current.side, distance: gap, dx: place.x - centre.x, dy: place.y - centre.y, x: place.x, y: place.y };
}

/** The nodes that follow a node because they are attached to it, directly or through others. */
export function followersOf(id: string, nodes: readonly Pick<PictureNode, "id" | "attached">[]): string[] {
  const found: string[] = [];
  const visit = (target: string): void => {
    for (const n of nodes) if (n.attached?.to === target && !found.includes(n.id) && n.id !== id) { found.push(n.id); visit(n.id); }
  };
  visit(id);
  return found;
}

/** The value an option list gives a key: the last one wins; `true` for a bare key, `undefined` when absent. */
export function optionOf(options: readonly PictureOption[], key: string): string | true | undefined {
  for (let i = options.length - 1; i >= 0; i -= 1) if (options[i]!.key === key) return options[i]!.value ?? true;
  return undefined;
}

type StyleChange = { readonly set: readonly PictureOption[]; readonly remove: readonly string[] };
interface StyleButton { readonly label: string; readonly title: string; readonly on: boolean; readonly swatch?: string; readonly change: StyleChange }

const fills: readonly { readonly name: string; readonly value: string | null; readonly swatch: string }[] = [
  { name: "No fill", value: null, swatch: "transparent" },
  { name: "Yellow", value: "yellow!30", swatch: "#ffffb3" },
  { name: "Blue", value: "blue!15", swatch: "#d9d9ff" },
  { name: "Green", value: "green!20", swatch: "#ccffcc" },
  { name: "Red", value: "red!15", swatch: "#ffd9d9" },
  { name: "Grey", value: "gray!20", swatch: "#e6e6e6" },
];

/** What the style bar offers for a node, with what is on now; each button is one option change. */
export function nodeStyleButtons(options: readonly PictureOption[]): StyleButton[][] {
  const fill = optionOf(options, "fill");
  const draw = optionOf(options, "draw");
  const bordered = draw !== undefined && draw !== "none";
  const shape = optionOf(options, "circle") !== undefined ? "circle" : optionOf(options, "rounded corners") !== undefined ? "rounded" : "square";
  const font = optionOf(options, "font");
  const size = typeof font === "string" && font.includes("\\small") ? "small" : typeof font === "string" && font.includes("\\large") ? "large" : "normal";
  const toggle = (key: string, on: boolean): StyleChange => on ? { set: [], remove: [key] } : { set: [{ key, value: null }], remove: [] };
  return [
    fills.map((f) => ({
      label: "", title: `Fill: ${f.name}`, swatch: f.swatch,
      on: f.value === null ? fill === undefined || fill === "none" : fill === f.value,
      change: f.value === null ? { set: [], remove: ["fill"] } : { set: [{ key: "fill", value: f.value }], remove: [] },
    })),
    [
      { label: "\u25a2", title: "Border", on: bordered, change: bordered ? { set: [], remove: ["draw"] } : { set: [{ key: "draw", value: null }], remove: [] } },
      { label: "\u2501", title: "Thick border", on: optionOf(options, "thick") !== undefined, change: toggle("thick", optionOf(options, "thick") !== undefined) },
      { label: "\u2504", title: "Dashed border", on: optionOf(options, "dashed") !== undefined, change: toggle("dashed", optionOf(options, "dashed") !== undefined) },
    ],
    [
      { label: "\u25ad", title: "Square corners", on: shape === "square", change: { set: [], remove: ["rounded corners", "circle"] } },
      { label: "\u25a2", title: "Rounded corners", on: shape === "rounded", change: { set: [{ key: "rounded corners", value: null }], remove: ["circle"] } },
      { label: "\u25ef", title: "Circle", on: shape === "circle", change: { set: [{ key: "circle", value: null }], remove: ["rounded corners"] } },
    ],
    [
      { label: "A", title: "Small text", on: size === "small", change: { set: [{ key: "font", value: "\\small" }], remove: [] } },
      { label: "A", title: "Normal text", on: size === "normal", change: { set: [], remove: ["font"] } },
      { label: "A", title: "Large text", on: size === "large", change: { set: [{ key: "font", value: "\\large" }], remove: [] } },
    ],
  ];
}

const arrowKeys = ["->", "<-", "<->", "-latex", "latex-", "latex-latex", "-stealth", "stealth-", "stealth-stealth", "->>", "-to"];

/** What the style bar offers for a line. */
export function lineStyleButtons(options: readonly PictureOption[]): StyleButton[][] {
  const has = (key: string): boolean => optionOf(options, key) !== undefined;
  const tip = has("<->") ? "<->" : has("->") ? "->" : has("<-") ? "<-" : "";
  const arrow = (label: string, title: string, key: string): StyleButton =>
    ({ label, title, on: tip === key, change: { set: key === "" ? [] : [{ key, value: null }], remove: arrowKeys.filter((k) => k !== key) } });
  const toggle = (label: string, title: string, key: string): StyleButton =>
    ({ label, title, on: has(key), change: has(key) ? { set: [], remove: [key] } : { set: [{ key, value: null }], remove: [] } });
  return [
    [arrow("\u2014", "No arrowhead", ""), arrow("\u2192", "Arrow at the end", "->"), arrow("\u2190", "Arrow at the start", "<-"), arrow("\u2194", "Arrows at both ends", "<->")],
    [toggle("\u2501", "Thick", "thick"), toggle("\u2504", "Dashed", "dashed")],
  ];
}

/** A node's turn in degrees, counter-clockwise as TikZ's `rotate` counts it. */
export function rotationOf(options: readonly PictureOption[]): number {
  const value = optionOf(options, "rotate");
  const degrees = typeof value === "string" ? Number(value) : 0;
  return Number.isFinite(degrees) ? degrees : 0;
}

/** Bring an angle into (-180, 180], so the written number stays short. */
export const normalDegrees = (degrees: number): number => { const d = ((degrees % 360) + 360) % 360; return d > 180 ? d - 360 : d; };

export type Alignment = "left" | "centre" | "right" | "top" | "middle" | "bottom";

/** How far each box moves to line up with the others: edges go to the outermost edge, centres to the middle of the group. */
export function alignDeltas(boxes: readonly Box[], how: Alignment): { dx: number; dy: number }[] {
  if (boxes.length === 0) return [];
  const left = Math.min(...boxes.map((b) => b.x)), right = Math.max(...boxes.map((b) => b.x + b.width));
  const top = Math.min(...boxes.map((b) => b.y)), bottom = Math.max(...boxes.map((b) => b.y + b.height));
  return boxes.map((b) => {
    switch (how) {
      case "left": return { dx: left - b.x, dy: 0 };
      case "right": return { dx: right - (b.x + b.width), dy: 0 };
      case "centre": return { dx: (left + right) / 2 - (b.x + b.width / 2), dy: 0 };
      case "top": return { dx: 0, dy: top - b.y };
      case "bottom": return { dx: 0, dy: bottom - (b.y + b.height) };
      case "middle": return { dx: 0, dy: (top + bottom) / 2 - (b.y + b.height / 2) };
    }
  });
}

/** How far each box moves so that the gaps between neighbours are equal; the two outermost stay. */
export function distributeDeltas(boxes: readonly Box[], axis: "x" | "y"): { dx: number; dy: number }[] {
  const start = (b: Box): number => axis === "x" ? b.x : b.y;
  const size = (b: Box): number => axis === "x" ? b.width : b.height;
  const order = boxes.map((b, i) => ({ b, i })).sort((p, q) => start(p.b) + size(p.b) / 2 - (start(q.b) + size(q.b) / 2));
  const deltas = boxes.map(() => ({ dx: 0, dy: 0 }));
  if (order.length < 3) return deltas;
  const first = order[0]!.b, last = order[order.length - 1]!.b;
  const free = start(last) + size(last) - start(first) - order.reduce((sum, p) => sum + size(p.b), 0);
  const gap = free / (order.length - 1);
  let at = start(first);
  for (const { b, i } of order) {
    const d = at - start(b);
    deltas[i] = axis === "x" ? { dx: d, dy: 0 } : { dx: 0, dy: d };
    at += size(b) + gap;
  }
  return deltas;
}

/**
 * A trail (an elbow or a curve) with its start and its end moved, as a preview while the nodes
 * at its ends are dragged: an elbow keeps its right angle, a curve carries its control points.
 */
export function shiftTrail(d: string, start: { dx: number; dy: number }, end: { dx: number; dy: number }): string {
  const steps = trailPoints(d);
  if (steps === null) return d;
  const moved = steps.map((s) => ({ command: s.command, points: s.points.map((p) => ({ x: p.x, y: p.y })) }));
  const first = moved[0]!.points[0]!;
  const lastStep = moved[moved.length - 1]!;
  const last = lastStep.points[lastStep.points.length - 1]!;
  if (moved.length === 3 && moved[1]!.command === "L" && moved[2]!.command === "L") {
    // the corner shares one coordinate with each end
    const corner = moved[1]!.points[0]!;
    const alongFirst = Math.abs(corner.y - first.y) <= Math.abs(corner.x - first.x);
    if (alongFirst) { corner.y += start.dy; corner.x += end.dx; } else { corner.x += start.dx; corner.y += end.dy; }
  } else if (moved.length === 2 && lastStep.command === "C") {
    lastStep.points[0]!.x += start.dx; lastStep.points[0]!.y += start.dy;
    lastStep.points[1]!.x += end.dx; lastStep.points[1]!.y += end.dy;
  }
  first.x += start.dx; first.y += start.dy;
  last.x += end.dx; last.y += end.dy;
  return trailData(moved);
}

/** The middle of a painted step and which way it travels there (plan pixels, y down). */
export function stepMiddle(el: { getAttribute(name: string): string | null }): { x: number; y: number; tx: number; ty: number } | null {
  const d = el.getAttribute("d");
  if (d === null) {
    const [x1, y1, x2, y2] = ["x1", "y1", "x2", "y2"].map((k) => Number(el.getAttribute(k)));
    return { x: (x1! + x2!) / 2, y: (y1! + y2!) / 2, tx: x2! - x1!, ty: y2! - y1! };
  }
  const steps = trailPoints(d);
  if (steps === null) return null;
  const a = steps[0]!.points[0]!;
  if (steps[1]!.command === "C") {
    const [c1, c2, b] = steps[1]!.points as [{ x: number; y: number }, { x: number; y: number }, { x: number; y: number }];
    return { x: (a.x + 3 * c1.x + 3 * c2.x + b.x) / 8, y: (a.y + 3 * c1.y + 3 * c2.y + b.y) / 8, tx: b.x - a.x, ty: b.y - a.y };
  }
  const corner = steps[1]!.points[0]!;
  const b = steps[steps.length - 1]!.points[0]!;
  return { x: corner.x, y: corner.y, tx: b.x - a.x, ty: b.y - a.y };
}

/**
 * The bend that makes a curve between two ends pass through a dragged point: degrees, positive to
 * the left of the direction of travel (as TikZ's `bend left`), in steps of 5 and at most 90.
 */
export function bendThrough(from: { x: number; y: number }, to: { x: number; y: number }, at: { x: number; y: number }): number {
  const [tx, ty] = [to.x - from.x, to.y - from.y];
  const length = Math.hypot(tx, ty);
  if (length === 0) return 0;
  // left of travel, with the screen's y pointing down
  const off = ((at.x - (from.x + to.x) / 2) * ty - (at.y - (from.y + to.y) / 2) * tx) / length;
  // a curve with TikZ's control points rises 0.75 * 0.3915 * length * sin(bend) at its middle
  const sine = Math.max(-1, Math.min(1, off / (0.2936 * length)));
  return Math.round((Math.asin(sine) * 180 / Math.PI) / 5) * 5;
}

/** What the bar offers for a line's route and its first label. */
export const routeIcons: readonly { readonly to: "straight" | "hv" | "vh" | "bend left"; readonly title: string; readonly icon: string }[] = [
  { to: "straight", title: "Straight", icon: "M2 13L14 3" },
  { to: "hv", title: "Right angle: across, then up or down", icon: "M2 4H13V13" },
  { to: "vh", title: "Right angle: up or down, then across", icon: "M3 3V12H14" },
  { to: "bend left", title: "Curved (again for the other way)", icon: "M2 12C5 2 11 2 14 12" },
];

const overlaps = (a: Box, b: Box): boolean => a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height;

/** A button of the bar: a look that is on or off, or something to do with what is selected. */
interface BarButton { readonly label: string; readonly title: string; readonly on: boolean; readonly swatch?: string; /** Drawn instead of the label: path data in a 16 by 16 box. */ readonly icon?: string; /** The icon is a line, not a filled shape. */ readonly open?: boolean; readonly size?: number; readonly act: () => void }

const alignIcons: readonly { readonly how: Alignment; readonly title: string; readonly icon: string }[] = [
  { how: "left", title: "Align left edges", icon: "M2 1v14M4 4h9v3H4zM4 9h6v3H4z" },
  { how: "centre", title: "Align centres left to right", icon: "M8 1v14M3 4h10v3H3zM5 9h6v3H5z" },
  { how: "right", title: "Align right edges", icon: "M14 1v14M3 4h9v3H3zM6 9h6v3H6z" },
  { how: "top", title: "Align top edges", icon: "M1 2h14M4 4v9h3V4zM9 4v6h3V4z" },
  { how: "middle", title: "Align centres top to bottom", icon: "M1 8h14M4 3v10h3V3zM9 5v6h3V5z" },
  { how: "bottom", title: "Align bottom edges", icon: "M1 14h14M4 3v9h3V3zM9 6v6h3V6z" },
];

interface Attached {
  readonly slide: HTMLElement;
  readonly plan: Plan;
  readonly layer: HTMLElement;
  readonly marks: SVGSVGElement;
  readonly targets: Map<string, HTMLElement>;
  /** While a drag is shown: for each line with labels, how far each of its end nodes has moved. */
  readonly labelShifts: Map<string, Map<string, { dx: number; dy: number }>>;
}

export function createCanvasEdit(options: CanvasEditOptions): CanvasEdit {
  const { doc } = options;
  const attached = new Map<string, Attached>();
  /** What is selected on one slide; the last item is the one the bar describes. */
  let selection: { frame: string; items: string[] } | null = null;
  /** The slide last worked on: where a paste or Ctrl+A goes when nothing is selected. */
  let lastFrame: string | null = null;
  /** What was copied here, for when the system clipboard cannot be read. */
  let copied: { text: string; frame: string; pastes: Map<string, number> } | null = null;
  /** A node to start typing in as soon as its slide is painted (it was just created). */
  /** What was being typed when a slide was repainted: the text and the selection in it. */
  interface Draft { readonly text: string; readonly start: number; readonly end: number }
  let typeNext: { frame: string; node: string; draft?: Draft } | null = null;
  let editor: { frame: string; node: string; close: (commit: boolean) => void; draft: () => Draft } | null = null;
  let menu: HTMLElement | null = null;
  let busy = false;

  const nodeOf = (a: Attached, id: string): PictureNode | undefined => a.plan.picture?.nodes.find((n) => n.id === id);
  const lineOf = (a: Attached, id: string): PictureLine | undefined => a.plan.picture?.lines.find((l) => l.id === id);
  const centreOf = (n: PictureNode): { x: number; y: number } => ({ x: n.box.x + n.box.width / 2, y: n.box.y + n.box.height / 2 });
  /** Client pixels per plan pixel of a painted slide (it changes with zoom). */
  const scaleOf = (a: Attached): number => a.slide.getBoundingClientRect().width / a.plan.size.width;
  const planPoint = (a: Attached, clientX: number, clientY: number): { x: number; y: number } => {
    const rect = a.slide.getBoundingClientRect();
    return { x: ((clientX - rect.left) / rect.width) * a.plan.size.width, y: ((clientY - rect.top) / rect.height) * a.plan.size.height };
  };

  async function run(frame: string, op: PictureOp): Promise<EditResult> {
    if (busy) return { ok: false, message: "still applying the previous edit" };
    busy = true;
    try {
      const result = await options.edit(frame, op);
      if (!result.ok) options.status(result.message);
      return result;
    } finally {
      busy = false;
    }
  }

  const ownNodes = (a: Attached, items: readonly string[]): PictureNode[] => items.map((id) => nodeOf(a, id)).filter((n): n is PictureNode => n !== undefined && n.from == null);
  const ownLines = (a: Attached, items: readonly string[]): PictureLine[] => items.map((id) => lineOf(a, id)).filter((l): l is PictureLine => l !== undefined && l.from == null);
  /** One edit for one change, a batch for several. */
  const together = (ops: readonly PictureOp[]): PictureOp | null => ops.length === 0 ? null : ops.length === 1 ? ops[0]! : { kind: "batch", ops };
  /** Run an edit and keep the same things selected (their ids do not change). */
  const apply = (a: Attached, ops: readonly PictureOp[]): void => { const op = together(ops); if (op !== null) void run(a.plan.frame, op); };

  /** The box around a line's painted segments. */
  function lineBox(a: Attached, id: string): Box | null {
    const segments = [...a.marks.querySelectorAll<SVGElement>(`.sb-edit-line[data-line="${CSS.escape(id)}"]`)];
    if (segments.length === 0) return null;
    const points = segments.flatMap((el) => {
      const d = el.getAttribute("d");
      if (d === null) return [{ x: Number(el.getAttribute("x1")), y: Number(el.getAttribute("y1")) }, { x: Number(el.getAttribute("x2")), y: Number(el.getAttribute("y2")) }];
      return (trailPoints(d) ?? []).flatMap((step) => step.points);
    });
    if (points.length === 0) return null;
    const xs = points.map((p) => p.x), ys = points.map((p) => p.y);
    return { x: Math.min(...xs), y: Math.min(...ys), width: Math.max(...xs) - Math.min(...xs), height: Math.max(...ys) - Math.min(...ys) };
  }

  /** The moves that shift the selected nodes: a node attached to another moving one follows it and needs none. */
  function moveOps(a: Attached, items: readonly string[], delta: (node: PictureNode) => { dx: number; dy: number }, together?: { dx: number; dy: number }): PictureOp[] {
    const all = a.plan.picture?.nodes ?? [];
    const nodes = ownNodes(a, items);
    const carried = new Set(nodes.flatMap((n) => followersOf(n.id, all)));
    const ops: PictureOp[] = [];
    // when everything moves by one distance, the written points of the selected lines move with it
    if (together !== undefined && (together.dx !== 0 || together.dy !== 0)) {
      for (const line of ownLines(a, items)) {
        (line.points ?? []).forEach((point, index) => {
          if (point !== null) ops.push({ kind: "move_point", line: line.id, point: index, x: point.x + together.dx, y: point.y + together.dy });
        });
      }
    }
    for (const n of nodes) {
      if (carried.has(n.id)) continue;
      const d = delta(n);
      if (d.dx !== 0 || d.dy !== 0) ops.push({ kind: "move_node", node: n.id, x: n.at.x + d.dx, y: n.at.y + d.dy });
    }
    // an included picture moves as a whole, once
    const seen = new Set<string>();
    for (const id of items) {
      const from = nodeOf(a, id)?.from;
      if (from == null || seen.has(from.cat)) continue;
      seen.add(from.cat);
      const d = delta(nodeOf(a, id)!);
      if (d.dx !== 0 || d.dy !== 0) ops.push({ kind: "move_include", item: from.cat, x: from.shift.x + d.dx, y: from.shift.y + d.dy });
    }
    return ops;
  }

  /** What the bar offers for what is selected: looks first, then turning, order and lining up. */
  function barGroups(a: Attached, items: readonly string[]): BarButton[][] {
    const nodes = ownNodes(a, items);
    const lines = ownLines(a, items);
    const last = items[items.length - 1];
    const lead = nodes.find((n) => n.id === last) ?? nodes[nodes.length - 1];
    const leadLine = lines.find((l) => l.id === last) ?? lines[lines.length - 1];
    const styled = (targets: readonly string[], change: StyleChange): void => apply(a, targets.map((item): PictureOp => ({ kind: "style", item, set: change.set, remove: change.remove })));
    const groups: BarButton[][] = [];
    if (lead !== undefined) {
      for (const group of nodeStyleButtons(lead.options)) groups.push(group.map((b, i): BarButton => ({ label: b.label, title: b.title, on: b.on, swatch: b.swatch, size: b.title.endsWith("text") ? i : undefined, act: () => styled(nodes.map((n) => n.id), b.change) })));
      const turnBy = (by: number): void => apply(a, nodes.map((n): PictureOp => {
        const next = normalDegrees(rotationOf(n.options) + by);
        return { kind: "style", item: n.id, set: next === 0 ? [] : [{ key: "rotate", value: String(next) }], remove: next === 0 ? ["rotate"] : [] };
      }));
      const mirror = (key: "xscale" | "yscale"): void => apply(a, nodes.map((n): PictureOp => {
        const flipped = Number(optionOf(n.options, key)) < 0;
        return { kind: "style", item: n.id, set: flipped ? [] : [{ key, value: "-1" }], remove: flipped ? [key] : [] };
      }));
      const turning: BarButton[] = [
        { label: "↺", title: "Turn left by a quarter", on: false, act: () => turnBy(90) },
        { label: "↻", title: "Turn right by a quarter", on: false, act: () => turnBy(-90) },
      ];
      // only a drawn outline has a left and a right to swap
      if (nodes.some((n) => optionOf(n.options, "outline") !== undefined)) {
        turning.push(
          { label: "⇆", title: "Flip left to right", on: Number(optionOf(lead.options, "xscale")) < 0, act: () => mirror("xscale") },
          { label: "⇅", title: "Flip top to bottom", on: Number(optionOf(lead.options, "yscale")) < 0, act: () => mirror("yscale") },
        );
      }
      groups.push(turning);
      if (nodes.length === 1 && items.length === 1) {
        const order = (to: "front" | "back" | "forward" | "backward") => (): void => {
          void run(a.plan.frame, { kind: "reorder", node: lead.id, to }).then((result) => {
            // an unnamed node is known by its place, which just changed
            if (result.ok && result.created !== null) select({ frame: a.plan.frame, item: result.created });
          });
        };
        groups.push([
          { label: "⤒", title: "Bring to front", on: false, act: order("front") },
          { label: "↑", title: "Bring forward", on: false, act: order("forward") },
          { label: "↓", title: "Send backward", on: false, act: order("backward") },
          { label: "⤓", title: "Send to back", on: false, act: order("back") },
        ]);
      }
      if (nodes.length > 1) {
        const boxes = nodes.map((n) => n.box);
        const shifted = (deltas: readonly { dx: number; dy: number }[]): void => apply(a, moveOps(a, nodes.map((n) => n.id), (n) => deltas[nodes.indexOf(n)] ?? { dx: 0, dy: 0 }));
        groups.push(alignIcons.map((icon): BarButton => ({ label: "", title: icon.title, icon: icon.icon, on: false, act: () => shifted(alignDeltas(boxes, icon.how)) })));
        if (nodes.length > 2) {
          groups.push([
            { label: "", title: "Space evenly left to right", icon: "M2 1v14M14 1v14M6 4h4v8H6z", on: false, act: () => shifted(distributeDeltas(boxes, "x")) },
            { label: "", title: "Space evenly top to bottom", icon: "M1 2h14M1 14h14M4 6h8v4H4z", on: false, act: () => shifted(distributeDeltas(boxes, "y")) },
          ]);
        }
      }
    } else if (leadLine !== undefined) {
      for (const group of lineStyleButtons(leadLine.options)) groups.push(group.map((b): BarButton => ({ label: b.label, title: b.title, on: b.on, act: () => styled(lines.map((l) => l.id), b.change) })));
      // how it goes: straight, at a right angle either way, or curved (again: the other way)
      const now = leadLine.joins?.[0] ?? "straight";
      groups.push(routeIcons.map((r): BarButton => ({
        label: "", title: r.title, icon: r.icon, open: true,
        on: r.to === "bend left" ? now === "bend left" || now === "bend right" || now === "curve" : now === r.to,
        act: () => apply(a, lines.map((l): PictureOp => ({ kind: "route", line: l.id, to: r.to === "bend left" && l.joins?.[0] === "bend left" ? "bend right" : r.to, bend: null }))),
      })));
      if (lines.length === 1 && items.length === 1) {
        const label = leadLine.labels?.[0];
        const labelled: BarButton[] = [{ label: "T", title: label === undefined ? "Add a label" : "Edit the label", on: false, act: () => startLabel(a.plan.frame, leadLine.id, label?.index ?? 0) }];
        if (label !== undefined) {
          const placing = ["auto", "swap", "above", "below", "left", "right", "above left", "above right", "below left", "below right", "sloped"];
          const side = optionOf(label.options, "auto") === undefined ? (placing.some((k) => optionOf(label.options, k) !== undefined) ? "other" : "on") : optionOf(label.options, "swap") !== undefined ? "swap" : "auto";
          const place = (set: readonly PictureOption[], remove: readonly string[]) => (): void => { void run(a.plan.frame, { kind: "label_style", line: leadLine.id, index: label.index, set, remove }); };
          labelled.push(
            { label: "", title: "Label on one side", icon: "M2 12H14M5 4h6v4H5z", on: side === "auto", act: place([{ key: "auto", value: null }], placing.filter((k) => k !== "auto").concat(["fill"])) },
            { label: "", title: "Label on the line", icon: "M2 8H4M12 8H14M5 6h6v4H5z", on: side === "on", act: place([{ key: "fill", value: "white" }], placing) },
            { label: "", title: "Label on the other side", icon: "M2 4H14M5 8h6v4H5z", on: side === "swap", act: place([{ key: "auto", value: null }, { key: "swap", value: null }], placing.filter((k) => k !== "auto" && k !== "swap").concat(["fill"])) },
          );
        }
        groups.push(labelled);
      }
    }
    return groups;
  }

  /** The floating bar for what is selected: one click, one change in the source. */
  function styleBar(): void {
    for (const a of attached.values()) for (const old of a.layer.querySelectorAll(".sb-style-bar")) old.remove();
    if (selection === null || editor !== null) return;
    const a = attached.get(selection.frame);
    if (a === undefined) return;
    const items = selection.items;
    const groups = barGroups(a, items);
    if (groups.length === 0) return;
    const bar = doc.createElement("div");
    bar.className = "sb-style-bar";
    bar.setAttribute("role", "toolbar");
    bar.setAttribute("aria-label", items.length > 1 ? `Looks and arrangement of the ${items.length} selected elements` : "Looks of the selected element");
    for (const group of groups) {
      const set = doc.createElement("span");
      set.className = "sb-style-group";
      for (const b of group) {
        const button = doc.createElement("button");
        button.type = "button";
        button.className = b.swatch === undefined ? "sb-style-button" : "sb-style-button sb-style-swatch";
        if (b.size !== undefined) button.dataset.size = String(b.size);
        button.title = b.title;
        button.setAttribute("aria-label", b.title);
        button.setAttribute("aria-pressed", String(b.on));
        button.textContent = b.label;
        if (b.icon !== undefined) {
          const svg = doc.createElementNS(svgNamespace, "svg");
          svg.setAttribute("viewBox", "0 0 16 16");
          svg.setAttribute("class", b.open === true ? "sb-style-icon is-open" : "sb-style-icon");
          const path = doc.createElementNS(svgNamespace, "path");
          path.setAttribute("d", b.icon);
          svg.append(path);
          button.append(svg);
        }
        if (b.swatch !== undefined) button.style.setProperty("--swatch", b.swatch);
        button.addEventListener("click", (event) => { event.stopPropagation(); b.act(); });
        set.append(button);
      }
      bar.append(set);
    }
    for (const type of ["pointerdown", "dblclick", "contextmenu"]) bar.addEventListener(type, (event) => event.stopPropagation());
    // above what is selected, or below it when there is no room; kept inside the slide sideways
    const { width, height } = a.plan.size;
    const boxes = items.map((id) => nodeOf(a, id)?.box ?? lineBox(a, id)).filter((b): b is Box => b !== null && b !== undefined);
    if (boxes.length === 0) return;
    const left = Math.min(...boxes.map((b) => b.x)), right = Math.max(...boxes.map((b) => b.x + b.width));
    const top = Math.min(...boxes.map((b) => b.y)), bottom = Math.max(...boxes.map((b) => b.y + b.height));
    // a turned node reaches further up than its box, and its turn handle sits above it
    // (the handles keep their size on screen, so their reach in plan pixels grows as the slide shrinks)
    const scale = scaleOf(a);
    const reach = (items.length === 1 ? 46 : 16) / (scale > 0 ? scale : 1);
    const above = top > reach + 84;
    bar.style.top = `${((above ? top - reach : bottom + 26) / height) * 100}%`;
    bar.dataset.side = above ? "above" : "below";
    a.layer.append(bar);
    const half = scale > 0 ? Math.min(bar.getBoundingClientRect().width / scale / 2 + 6, width / 2) : 190;
    bar.style.left = `${(Math.min(Math.max((left + right) / 2, half), width - half) / width) * 100}%`;
  }

  function selectMany(frame: string | null, items: readonly string[]): void {
    selection = frame === null || items.length === 0 ? null : { frame, items: [...new Set(items)] };
    if (frame !== null) lastFrame = frame;
    for (const [f, a] of attached) {
      const on = (id: string | undefined): boolean => selection !== null && selection.frame === f && id !== undefined && selection.items.includes(id);
      for (const [id, el] of a.targets) {
        el.classList.toggle("is-selected", on(id));
        el.classList.toggle("is-alone", on(id) && selection !== null && selection.items.length === 1);
      }
      for (const hit of a.marks.querySelectorAll<SVGElement>(".sb-edit-line")) hit.classList.toggle("is-selected", on(hit.dataset.line));
    }
    styleBar();
    lineHandles();
  }

  /** The handles of the one selected line: its written points, a dot on each straight step to pull a new point out of, and one on a curve to bend it. */
  function lineHandles(): void {
    for (const a of attached.values()) for (const old of a.layer.querySelectorAll(".sb-line-point")) old.remove();
    if (selection === null || selection.items.length !== 1 || editor !== null) return;
    const a = attached.get(selection.frame);
    const line = a === undefined ? undefined : lineOf(a, selection.items[0]!);
    if (a === undefined || line === undefined || line.from != null) return;
    const { width, height } = a.plan.size;
    const handle = (kind: string, at: { x: number; y: number }, title: string): HTMLElement => {
      const el = doc.createElement("span");
      el.className = `sb-line-point sb-line-point-${kind}`;
      el.title = title;
      el.style.left = `${(at.x / width) * 100}%`;
      el.style.top = `${(at.y / height) * 100}%`;
      a.layer.append(el);
      return el;
    };
    /** Drag a handle; `drop` gets where it was let go, in plan pixels. */
    const draggable = (el: HTMLElement, drop: (at: { x: number; y: number }) => void, snap: boolean): void => {
      el.addEventListener("pointerdown", (down) => {
        if (down.button !== 0) return;
        down.stopPropagation();
        down.preventDefault();
        let at: { x: number; y: number } | null = null;
        try { el.setPointerCapture(down.pointerId); } catch { /* synthetic input */ }
        const move = (event: PointerEvent): void => {
          const now = planPoint(a, event.clientX, event.clientY);
          if (at === null && Math.hypot(event.clientX - down.clientX, event.clientY - down.clientY) < 4) return;
          if (at === null) for (const bar of a.layer.querySelectorAll(".sb-style-bar")) bar.remove();
          at = snap && !event.altKey ? { x: toGrid(now.x, 8), y: toGrid(now.y, 8) } : now;
          el.style.left = `${(at.x / width) * 100}%`;
          el.style.top = `${(at.y / height) * 100}%`;
          el.classList.add("is-moving");
        };
        const finish = (event: PointerEvent): void => {
          el.removeEventListener("pointermove", move);
          el.removeEventListener("pointerup", finish);
          el.removeEventListener("pointercancel", finish);
          // a press without a drag leaves the handle be, so a double-click reaches it
          if (at === null) return;
          if (event.type === "pointercancel") { lineHandles(); styleBar(); return; }
          drop(at);
        };
        el.addEventListener("pointermove", move);
        el.addEventListener("pointerup", finish);
        el.addEventListener("pointercancel", finish);
      });
      for (const type of ["click", "contextmenu"]) el.addEventListener(type, (event) => event.stopPropagation());
    };
    const edit = (op: PictureOp): void => { void run(a.plan.frame, op).then((result) => { if (!result.ok) { lineHandles(); styleBar(); } }); };
    (line.points ?? []).forEach((point, index) => {
      if (point === null) return;
      const inner = index > 0 && index < (line.points?.length ?? 0) - 1;
      const el = handle("at", point, inner ? "Drag to move this point; double-click to take it out" : "Drag to move this end");
      draggable(el, (at) => edit({ kind: "move_point", line: line.id, point: index, x: at.x, y: at.y }), true);
      el.addEventListener("dblclick", (event) => { event.stopPropagation(); if (inner) edit({ kind: "remove_point", line: line.id, point: index }); });
    });
    (line.joins ?? []).forEach((join, k) => {
      const painted = a.slide.querySelector(`.sb-layer-geometry [data-item-id="${CSS.escape(`${line.item}-${k + 1}`)}"]`);
      const middle = painted === null ? null : stepMiddle(painted);
      if (painted === null || middle === null) return;
      if (join === "straight") {
        const el = handle("new", middle, "Drag to bend the line through a point");
        draggable(el, (at) => edit({ kind: "add_point", line: line.id, step: k + 1, x: at.x, y: at.y }), true);
        for (const type of ["dblclick"]) el.addEventListener(type, (event) => { event.stopPropagation(); startLabel(a.plan.frame, line.id, line.labels?.[0]?.index ?? 0); });
      } else if ((join === "bend left" || join === "bend right") && (line.joins?.length ?? 0) === 1) {
        const steps = trailPoints(painted.getAttribute("d"));
        if (steps === null) return;
        const from = steps[0]!.points[0]!, to = steps[1]!.points[steps[1]!.points.length - 1]!;
        const el = handle("bend", middle, "Drag to bend more, less or the other way");
        draggable(el, (at) => {
          const degrees = bendThrough(from, to, at);
          edit(degrees === 0 ? { kind: "route", line: line.id, to: "straight", bend: null } : { kind: "route", line: line.id, to: degrees > 0 ? "bend left" : "bend right", bend: Math.abs(degrees) });
        }, false);
      }
    });
  }
  const select = (next: { frame: string; item: string } | null): void => selectMany(next?.frame ?? null, next === null ? [] : [next.item]);

  // --- creation menu ------------------------------------------------------------------
  function closeMenu(): void { menu?.remove(); menu = null; }

  function openMenu(a: Attached, clientX: number, clientY: number, then?: (created: string) => Promise<void>): void {
    closeMenu();
    const at = planPoint(a, clientX, clientY);
    const box = doc.createElement("div");
    box.className = "sb-create-menu";
    box.style.left = `${clientX}px`;
    box.style.top = `${clientY}px`;
    const input = doc.createElement("input");
    input.type = "text";
    input.placeholder = "Add... (type to filter)";
    input.setAttribute("aria-label", "Add an element; type to filter");
    const list = doc.createElement("div");
    list.className = "sb-create-list";
    list.setAttribute("role", "listbox");
    box.append(input, list);
    let shown: Preset[] = [];
    let index = 0;
    let library: ShapeLibrary | null = null;
    const pick = (preset: Preset | undefined): void => {
      if (preset === undefined) return;
      const query = input.value;
      closeMenu();
      if (preset.browse === true) { if (library !== null) openShapePanel(a, library, at, clientX, clientY, query, then); return; }
      if (preset.shape !== undefined) { void addShape(a, preset.shape, at, then); return; }
      if (preset.body === true) { startWriting(a.plan.frame, "body"); return; }
      if (preset.include !== undefined) { void run(a.plan.frame, { kind: "add_include", path: preset.include, x: 0, y: 0 }); return; }
      void (async () => {
        const made = await run(a.plan.frame, { kind: "add_node", options: preset.options, x: toGrid(at.x, 8), y: toGrid(at.y, 8), text: preset.text });
        if (!made.ok || made.created === null) return;
        if (then !== undefined) await then(made.created);
        startTyping(a.plan.frame, made.created, true);
      })();
    };
    const render = (): void => {
      const extra: Preset[] = then !== undefined ? [] : [
        ...(bodyOf(a)?.source === "" ? [slideTextPreset] : []),
        ...(options.pictureFiles?.() ?? []).map((path): Preset => ({ label: path.replace(/^.*\//, ""), hint: `picture file ${path}`, options: "", text: "", include: path })),
      ];
      shown = filterPresets(input.value, [...presets, ...extra]);
      // library shapes: the best few for what is typed, and the way to all of them
      if (library !== null) {
        const typed = input.value.trim();
        const found = typed.length >= 2 ? library.search(typed) : [];
        shown = [...shown, ...found.slice(0, menuShapeLimit).map(shapePreset), {
          label: typed.length >= 2 && found.length > menuShapeLimit ? `${found.length - menuShapeLimit} more shapes...` : "All shapes...",
          hint: `${library.shapes.length} in the library`, options: "", text: "", browse: true,
        }];
      }
      index = Math.min(index, Math.max(0, shown.length - 1));
      list.replaceChildren(...shown.map((preset, i) => {
        const row = doc.createElement("button");
        row.type = "button";
        row.className = "sb-create-item";
        row.setAttribute("role", "option");
        row.setAttribute("aria-selected", String(i === index));
        const name = doc.createElement("span");
        name.textContent = preset.label;
        const hint = doc.createElement("small");
        hint.textContent = preset.hint;
        if (preset.shape !== undefined) { row.classList.add("has-shape"); row.append(shapeThumbnail(doc, preset.shape, 22)); }
        row.append(name, hint);
        row.addEventListener("click", () => pick(preset));
        return row;
      }));
      // keep the whole menu on screen: it opens at the pointer, which may be near an edge
      const view = doc.defaultView;
      const size = box.getBoundingClientRect();
      if (view !== null && size.height > 0) {
        box.style.left = `${Math.max(8, Math.min(clientX, view.innerWidth - size.width - 8))}px`;
        box.style.top = `${Math.max(8, Math.min(clientY, view.innerHeight - size.height - 8))}px`;
      }
    };
    if (options.shapes !== undefined) void options.shapes().then((loaded) => { library = loaded; if (menu === box) render(); }, () => { /* no library in this build */ });
    input.addEventListener("input", () => { index = 0; render(); });
    input.addEventListener("keydown", (event) => {
      if (event.key === "ArrowDown") { index = Math.min(shown.length - 1, index + 1); render(); event.preventDefault(); }
      else if (event.key === "ArrowUp") { index = Math.max(0, index - 1); render(); event.preventDefault(); }
      else if (event.key === "Enter") { pick(shown[index]); event.preventDefault(); }
      else if (event.key === "Escape") { closeMenu(); event.preventDefault(); }
      event.stopPropagation();
    });
    box.addEventListener("pointerdown", (event) => event.stopPropagation());
    doc.body.append(box);
    menu = box;
    render();
    input.focus();
  }

  // --- library shapes -----------------------------------------------------------------
  /** Put a library shape on the slide at a plan point; it comes selected, ready to move or resize. */
  async function addShape(a: Attached, shape: Shape, at: { x: number; y: number }, then?: (created: string) => Promise<void>): Promise<void> {
    const made = await run(a.plan.frame, { kind: "add_node", options: shape.id, x: toGrid(at.x, 8), y: toGrid(at.y, 8), text: "" });
    if (!made.ok || made.created === null) return;
    if (then !== undefined) await then(made.created);
    select({ frame: a.plan.frame, item: made.created });
  }

  /** Every library shape: groups on the left, drawings on the right, a search box on top. */
  function openShapePanel(a: Attached, library: ShapeLibrary, at: { x: number; y: number }, clientX: number, clientY: number, query: string, then?: (created: string) => Promise<void>): void {
    closeMenu();
    const view = doc.defaultView;
    const panel = doc.createElement("div");
    panel.className = "sb-shape-panel";
    panel.setAttribute("role", "dialog");
    panel.setAttribute("aria-label", "Shape library");
    panel.style.left = `${Math.max(8, Math.min(clientX, (view?.innerWidth ?? 1200) - 640))}px`;
    panel.style.top = `${Math.max(8, Math.min(clientY, (view?.innerHeight ?? 800) - 470))}px`;
    const input = doc.createElement("input");
    input.type = "text";
    input.value = query;
    input.placeholder = "Search shapes";
    input.setAttribute("aria-label", "Search shapes");
    const groups = doc.createElement("div");
    groups.className = "sb-shape-groups";
    const grid = doc.createElement("div");
    grid.className = "sb-shape-grid";
    grid.setAttribute("role", "listbox");
    const note = doc.createElement("div");
    note.className = "sb-shape-note";
    const body = doc.createElement("div");
    body.className = "sb-shape-body";
    body.append(groups, grid);
    panel.append(input, body, note);
    let group: string | null = null;
    const render = (): void => {
      groups.replaceChildren(...[{ name: null as string | null, label: "All", count: library.shapes.length }, ...library.groups.map((g) => ({ name: g.name as string | null, label: g.name, count: g.count }))].map((g) => {
        const row = doc.createElement("button");
        row.type = "button";
        row.className = "sb-shape-group";
        row.setAttribute("aria-pressed", String(g.name === group));
        row.textContent = g.label;
        const count = doc.createElement("small");
        count.textContent = String(g.count);
        row.append(count);
        row.addEventListener("click", () => { group = g.name; render(); grid.scrollTop = 0; });
        return row;
      }));
      const found = library.search(input.value.trim(), group);
      grid.replaceChildren(...found.slice(0, panelShapeLimit).map((shape) => {
        const cell = doc.createElement("button");
        cell.type = "button";
        cell.className = "sb-shape-cell";
        cell.setAttribute("role", "option");
        cell.title = `${shape.label} (${shape.category})`;
        cell.dataset.shape = shape.id;
        const label = doc.createElement("span");
        label.textContent = shape.label;
        cell.append(shapeThumbnail(doc, shape, 44), label);
        cell.addEventListener("click", () => { closeMenu(); void addShape(a, shape, at, then); });
        return cell;
      }));
      note.textContent = found.length === 0 ? "No shape matches." : found.length > panelShapeLimit ? `Showing ${panelShapeLimit} of ${found.length}; type or pick a group to narrow.` : `${found.length} shape${found.length === 1 ? "" : "s"}`;
    };
    input.addEventListener("input", render);
    input.addEventListener("keydown", (event) => {
      if (event.key === "Escape") { closeMenu(); event.preventDefault(); }
      else if (event.key === "Enter") { (grid.firstElementChild as HTMLElement | null)?.click(); event.preventDefault(); }
      event.stopPropagation();
    });
    panel.addEventListener("pointerdown", (event) => event.stopPropagation());
    panel.addEventListener("wheel", (event) => event.stopPropagation(), { passive: true });
    doc.body.append(panel);
    menu = panel;
    render();
    input.focus();
  }

  // --- typing in a node ---------------------------------------------------------------
  function startTyping(frame: string, id: string, fresh = false, draft?: Draft): void {
    const a = attached.get(frame);
    const node = a === undefined ? undefined : nodeOf(a, id);
    if (a === undefined || node === undefined) { typeNext = { frame, node: id }; return; }
    typeNext = null;
    editor?.close(true);
    select({ frame, item: id });
    const area = doc.createElement("textarea");
    area.className = "sb-node-editor";
    area.value = draft?.text ?? node.source;
    area.spellcheck = false;
    area.setAttribute("aria-label", "Node text (Markdown, LaTeX or HTML); Enter to apply, Escape to cancel");
    const { width, height } = a.plan.size;
    const wide = Math.max(node.box.width, 220);
    area.style.left = `${((node.box.x + node.box.width / 2 - wide / 2) / width) * 100}%`;
    area.style.top = `${(node.box.y / height) * 100}%`;
    area.style.width = `${(wide / width) * 100}%`;
    area.style.minHeight = `${(node.box.height / height) * 100}%`;
    area.rows = Math.max(1, node.source.split("\n").length);
    let done = false;
    const close = (commit: boolean): void => {
      if (done) return;
      done = true;
      editor = null;
      const text = area.value;
      area.remove();
      styleBar();
      if (!commit || text === node.source) return;
      void run(frame, text.trim() === "" ? { kind: "delete", item: id } : { kind: "set_text", node: id, text });
    };
    area.addEventListener("keydown", (event) => {
      if (event.key === "Enter" && !event.shiftKey) { close(true); event.preventDefault(); }
      else if (event.key === "Escape") { close(false); event.preventDefault(); }
      event.stopPropagation();
    });
    area.addEventListener("blur", () => close(true));
    for (const type of ["pointerdown", "dblclick", "click", "contextmenu"]) area.addEventListener(type, (event) => event.stopPropagation());
    a.layer.append(area);
    editor = { frame, node: id, close, draft: () => ({ text: area.value, start: area.selectionStart, end: area.selectionEnd }) };
    styleBar();
    area.focus();
    if (draft !== undefined) area.setSelectionRange(draft.start, draft.end);
    else if (fresh) area.select();
  }

  /** Type a line's label where it is (or where it will be): `index` 0 adds one. */
  function startLabel(frame: string, lineId: string, index: number, fresh = false, draft?: Draft): void {
    const a = attached.get(frame);
    const line = a === undefined ? undefined : lineOf(a, lineId);
    if (a === undefined || line === undefined || line.from != null) return;
    const label = line.labels?.find((l) => l.index === index);
    const around = label?.box ?? lineBox(a, lineId);
    if (around === null) return;
    typeNext = null;
    editor?.close(true);
    select({ frame, item: lineId });
    const area = doc.createElement("textarea");
    area.className = "sb-node-editor sb-label-editor";
    area.value = draft?.text ?? label?.source ?? "";
    area.spellcheck = false;
    area.rows = 1;
    area.placeholder = "Label";
    area.setAttribute("aria-label", "Label of the line (Markdown, LaTeX or HTML); Enter to apply, Escape to cancel; empty removes it");
    const { width, height } = a.plan.size;
    const wide = Math.max(around.width, 160);
    const centre = { x: around.x + around.width / 2, y: around.y + around.height / 2 };
    area.style.left = `${((centre.x - wide / 2) / width) * 100}%`;
    area.style.top = `${((centre.y - 18) / height) * 100}%`;
    area.style.width = `${(wide / width) * 100}%`;
    let done = false;
    const close = (commit: boolean): void => {
      if (done) return;
      done = true;
      editor = null;
      const text = area.value;
      area.remove();
      styleBar();
      lineHandles();
      if (!commit || text === (label?.source ?? "") || (label === undefined && text.trim() === "")) return;
      void run(frame, { kind: "label", line: lineId, index: label?.index ?? 0, text });
    };
    area.addEventListener("keydown", (event) => {
      if (event.key === "Enter" && !event.shiftKey) { close(true); event.preventDefault(); }
      else if (event.key === "Escape") { close(false); event.preventDefault(); }
      event.stopPropagation();
    });
    area.addEventListener("blur", () => close(true));
    for (const type of ["pointerdown", "dblclick", "click", "contextmenu"]) area.addEventListener(type, (event) => event.stopPropagation());
    a.layer.append(area);
    editor = { frame, node: `label:${index}:${lineId}`, close, draft: () => ({ text: area.value, start: area.selectionStart, end: area.selectionEnd }) };
    styleBar();
    lineHandles();
    area.focus();
    if (draft !== undefined) area.setSelectionRange(draft.start, draft.end);
    else if (fresh) area.select(); else area.setSelectionRange(area.value.length, area.value.length);
  }

  // --- typing the slide's own title and text ------------------------------------------
  const writtenOf = (a: Attached, part: string): WrittenText | undefined => a.plan.written?.find((w) => w.part === part);
  const bodyOf = (a: Attached): WrittenText | undefined => writtenOf(a, "body");
  const paintedOf = (a: Attached, part: string): HTMLElement | null => a.slide.querySelector<HTMLElement>(`.sb-layer-content > .sb-item[data-item-id="${part}"]`);

  /** The part of the slide's own text under a point: only where its words are, not the whole region. */
  function writtenAt(a: Attached, event: MouseEvent): "title" | "body" | null {
    for (const part of ["title", "body"] as const) {
      const painted = paintedOf(a, part);
      if (painted === null || writtenOf(a, part) === undefined || painted.childNodes.length === 0) continue;
      const range = doc.createRange();
      range.selectNodeContents(painted);
      const r = range.getBoundingClientRect();
      const slack = 6;
      if (r.width > 0 && event.clientX >= r.left - slack && event.clientX <= r.right + slack && event.clientY >= r.top - slack && event.clientY <= r.bottom + slack) return part;
    }
    return null;
  }

  function startWriting(frame: string, part: "title" | "body", draft?: Draft): void {
    const a = attached.get(frame);
    const written = a === undefined ? undefined : writtenOf(a, part);
    const region = a?.plan.picture?.regions.find((r) => r.id === part)?.box;
    if (a === undefined || written === undefined || region === undefined || options.write === undefined) return;
    const write = options.write;
    typeNext = null;
    editor?.close(true);
    select(null);
    const painted = paintedOf(a, part);
    const area = doc.createElement("textarea");
    area.className = `sb-node-editor sb-text-editor sb-text-editor-${part}`;
    area.value = draft?.text ?? written.source;
    area.spellcheck = false;
    area.placeholder = part === "title" ? "Title" : "Type the slide's text (Markdown, LaTeX or HTML)";
    area.setAttribute("aria-label", part === "title" ? "Slide title; Enter to apply, Escape to cancel" : "Slide text (Markdown, LaTeX or HTML); Ctrl+Enter or click away to apply, Escape to cancel");
    const { width, height } = a.plan.size;
    area.style.left = `${(region.x / width) * 100}%`;
    area.style.top = `${(region.y / height) * 100}%`;
    area.style.width = `${(region.width / width) * 100}%`;
    if (painted !== null) {
      const style = doc.defaultView?.getComputedStyle(painted);
      if (style !== undefined) { area.style.fontSize = style.fontSize; area.style.fontWeight = style.fontWeight; area.style.fontFamily = style.fontFamily; area.style.lineHeight = style.lineHeight; }
      painted.style.visibility = "hidden";
    }
    const fit = (): void => { area.style.height = "auto"; area.style.height = `${area.scrollHeight + 4}px`; };
    let done = false;
    const close = (commit: boolean): void => {
      if (done) return;
      done = true;
      editor = null;
      const typed = area.value;
      area.remove();
      if (painted !== null) painted.style.visibility = "";
      const replacement = commit ? writtenReplacement(written, typed) : null;
      if (replacement === null) return;
      void (async () => {
        const result = await write(written.span, written.source, replacement);
        if (!result.ok) options.status(result.message);
      })();
    };
    area.addEventListener("input", fit);
    area.addEventListener("keydown", (event) => {
      const apply = event.key === "Enter" && (part === "title" ? !event.shiftKey : event.ctrlKey || event.metaKey);
      if (apply) { close(true); event.preventDefault(); }
      else if (event.key === "Escape") { close(false); event.preventDefault(); }
      event.stopPropagation();
    });
    area.addEventListener("blur", () => close(true));
    for (const type of ["pointerdown", "dblclick", "click", "contextmenu"]) area.addEventListener(type, (event) => event.stopPropagation());
    a.layer.append(area);
    editor = { frame, node: `written:${part}`, close, draft: () => ({ text: area.value, start: area.selectionStart, end: area.selectionEnd }) };
    fit();
    area.focus();
    if (draft !== undefined) area.setSelectionRange(draft.start, draft.end);
    else area.setSelectionRange(area.value.length, area.value.length);
  }

  // --- dragging -----------------------------------------------------------------------
  /** Show a node moved by a plan-pixel delta and turned (a preview; the repaint replaces it). */
  function poseNode(a: Attached, node: PictureNode, dx: number, dy: number, degrees: number = rotationOf(node.options)): void {
    const scale = scaleOf(a);
    const css = [dx === 0 && dy === 0 ? "" : `translate(${dx * scale}px, ${dy * scale}px)`, degrees === 0 ? "" : `rotate(${-degrees}deg)`].filter((t) => t !== "").join(" ");
    for (const el of a.slide.querySelectorAll<HTMLElement>(`.sb-item[data-item-id="${CSS.escape(`pic-${node.id}`)}"]`)) el.style.transform = css;
    const target = a.targets.get(node.id);
    if (target !== undefined) target.style.transform = css;
    const background = a.slide.querySelector(`[data-item-id="${CSS.escape(`pic-bg-${node.id}`)}"]`);
    if (background !== null) {
      const holder = background.closest("g.sb-turn") ?? background;
      const centre = centreOf(node);
      const svg = [dx === 0 && dy === 0 ? "" : `translate(${dx} ${dy})`, degrees === 0 ? "" : `rotate(${-degrees} ${centre.x} ${centre.y})`].filter((t) => t !== "").join(" ");
      if (svg === "") holder.removeAttribute("transform"); else holder.setAttribute("transform", svg);
    }
  }

  function shiftNode(a: Attached, node: PictureNode, dx: number, dy: number): void {
    poseNode(a, node, dx, dy);
    for (const line of a.plan.picture?.lines ?? []) {
      // a label rides its line: it goes half the way of each end that moves
      if (line.ends.includes(node.id) && (line.labels ?? []).length > 0) {
        const shifts = (a.labelShifts.get(line.id) ?? new Map<string, { dx: number; dy: number }>()).set(node.id, { dx, dy });
        a.labelShifts.set(line.id, shifts);
        const ends = line.ends.filter((end) => end !== null).length || 1;
        const sum = [...shifts.values()].reduce((acc, one) => ({ dx: acc.dx + one.dx, dy: acc.dy + one.dy }), { dx: 0, dy: 0 });
        const by = { dx: sum.dx / Math.max(2, ends), dy: sum.dy / Math.max(2, ends) };
        const scale = scaleOf(a);
        const stem = line.id.replace(/^line-/, "label-");
        for (const label of line.labels ?? []) {
          const css = by.dx === 0 && by.dy === 0 ? "" : `translate(${by.dx * scale}px, ${by.dy * scale}px)`;
          for (const el of a.slide.querySelectorAll<HTMLElement>(`.sb-item[data-item-id="${CSS.escape(`pic-${stem}-${label.index}`)}"]`)) el.style.transform = css;
          const background = a.slide.querySelector(`[data-item-id="${CSS.escape(`pic-bg-${stem}-${label.index}`)}"]`);
          if (background !== null) { if (css === "") background.removeAttribute("transform"); else background.setAttribute("transform", `translate(${by.dx} ${by.dy})`); }
        }
      }
      line.ends.forEach((end, k) => {
        if (end !== node.id) return;
        // end k closes segment k and opens segment k+1 (segments are numbered from 1)
        for (const [segment, x, y] of [[k, "x2", "y2"], [k + 1, "x1", "y1"]] as const) {
          for (const el of a.slide.querySelectorAll<SVGElement>(`[data-item-id="${CSS.escape(`${line.item}-${segment}`)}"], [data-segment="${CSS.escape(`${line.item}-${segment}`)}"]`)) {
            if (el.hasAttribute("d")) {
              const base = el.dataset.dBase ?? (el.dataset.dBase = el.getAttribute("d") ?? "");
              el.dataset[x === "x2" ? "endShift" : "startShift"] = `${dx} ${dy}`;
              const read = (text: string | undefined): { dx: number; dy: number } => { const [sx, sy] = (text ?? "0 0").split(" ").map(Number); return { dx: sx ?? 0, dy: sy ?? 0 }; };
              el.setAttribute("d", shiftTrail(base, read(el.dataset.startShift), read(el.dataset.endShift)));
              continue;
            }
            const baseX = el.dataset[`${x}Base`] ?? (el.dataset[`${x}Base`] = el.getAttribute(x) ?? "0");
            const baseY = el.dataset[`${y}Base`] ?? (el.dataset[`${y}Base`] = el.getAttribute(y) ?? "0");
            el.setAttribute(x, String(Number(baseX) + dx));
            el.setAttribute(y, String(Number(baseY) + dy));
          }
        }
      });
    }
  }

  function guides(a: Attached, guideX: number | null, guideY: number | null): void {
    for (const old of a.marks.querySelectorAll(".sb-edit-guide")) old.remove();
    const add = (x1: number, y1: number, x2: number, y2: number): void => {
      const line = doc.createElementNS(svgNamespace, "line");
      line.setAttribute("class", "sb-edit-guide");
      for (const [k, v] of [["x1", x1], ["y1", y1], ["x2", x2], ["y2", y2]] as const) line.setAttribute(k, String(v));
      a.marks.append(line);
    };
    if (guideX !== null) add(guideX, 0, guideX, a.plan.size.height);
    if (guideY !== null) add(0, guideY, a.plan.size.width, guideY);
  }

  /** The dashed link shown while a dragged box sits in a place beside another. */
  function tether(a: Attached, link: { from: { x: number; y: number }; to: { x: number; y: number } } | null): void {
    for (const old of a.marks.querySelectorAll(".sb-edit-tether-live")) old.remove();
    if (link === null) return;
    const line = doc.createElementNS(svgNamespace, "line");
    line.setAttribute("class", "sb-edit-tether sb-edit-tether-live");
    for (const [k, v] of [["x1", link.from.x], ["y1", link.from.y], ["x2", link.to.x], ["y2", link.to.y]] as const) line.setAttribute(k, String(v));
    a.marks.append(line);
  }

  function dragNode(a: Attached, node: PictureNode, down: PointerEvent, target: HTMLElement): void {
    const start = planPoint(a, down.clientX, down.clientY);
    const all = a.plan.picture?.nodes ?? [];
    // what is attached to the dragged node travels with it, and cannot be what it attaches to
    const followers = followersOf(node.id, all).map((id) => nodeOf(a, id)).filter((n): n is PictureNode => n !== undefined);
    const free = all.filter((n) => n.id !== node.id && !followers.includes(n) && (n.from == null || n.named));
    const others = free.map(centreOf);
    const distance = a.plan.picture?.distance ?? 60;
    // the slide's own title and body take attachments above and below only
    const targets: Target[] = [
      ...free.map((n) => ({ id: n.id, box: n.box })),
      ...(a.plan.picture?.regions ?? []).map((r) => ({ id: r.id, box: r.box, sides: ["below", "above"] as const })),
    ];
    const boxOf = (id: string): Box | undefined => targets.find((t) => t.id === id)?.box;
    let moved = false;
    let last = { dx: 0, dy: 0 };
    let slot: Slot | null = null;
    const shiftAll = (dx: number, dy: number): void => { for (const n of [node, ...followers]) shiftNode(a, n, dx, dy); };
    try { target.setPointerCapture(down.pointerId); } catch { /* synthetic input */ }
    const move = (event: PointerEvent): void => {
      const now = planPoint(a, event.clientX, event.clientY);
      const raw = { x: now.x - start.x, y: now.y - start.y };
      if (!moved && Math.hypot(raw.x, raw.y) * scaleOf(a) < 4) return;
      if (!moved) for (const bar of a.layer.querySelectorAll(".sb-style-bar")) bar.remove();
      moved = true;
      // a place beside another box wins; then lining up with a centre; then the grid
      slot = event.altKey ? null : attachSlot(node.box, raw, targets, distance, 30, node.attached);
      for (const [id, el] of a.targets) el.classList.toggle("is-drop", slot !== null && id === slot.to);
      const anchor = slot === null ? undefined : boxOf(slot.to);
      tether(a, slot === null || anchor === undefined ? null : { from: { x: anchor.x + anchor.width / 2, y: anchor.y + anchor.height / 2 }, to: { x: slot.x, y: slot.y } });
      if (slot !== null) {
        last = { dx: slot.dx, dy: slot.dy };
        shiftAll(last.dx, last.dy);
        guides(a, null, null);
        return;
      }
      const snapped = event.altKey ? { dx: raw.x, dy: raw.y, guideX: null, guideY: null } : snapDelta(centreOf(node), raw, others, 10);
      // off a guide, land on a twentieth of a slide unit so the written point stays short
      last = {
        dx: snapped.guideX === null ? toGrid(node.at.x + snapped.dx, 4) - node.at.x : snapped.dx,
        dy: snapped.guideY === null ? toGrid(node.at.y + snapped.dy, 4) - node.at.y : snapped.dy,
      };
      shiftAll(last.dx, last.dy);
      guides(a, snapped.guideX, snapped.guideY);
    };
    const finish = (event: PointerEvent): void => {
      target.removeEventListener("pointermove", move);
      target.removeEventListener("pointerup", finish);
      target.removeEventListener("pointercancel", finish);
      guides(a, null, null);
      tether(a, null);
      for (const el of a.targets.values()) el.classList.remove("is-drop");
      const stays = slot !== null && node.attached !== null && node.attached.to === slot.to && node.attached.side === slot.side && node.attached.distance === slot.distance;
      if (!moved || event.type === "pointercancel" || stays || (slot === null && last.dx === 0 && last.dy === 0)) { shiftAll(0, 0); styleBar(); return; }
      const op: PictureOp = slot !== null
        ? { kind: "attach", node: node.id, side: slot.side, to: slot.to, distance: slot.distance }
        : { kind: "move_node", node: node.id, x: node.at.x + last.dx, y: node.at.y + last.dy };
      void run(a.plan.frame, op).then((result) => { if (!result.ok) shiftAll(0, 0); });
    };
    target.addEventListener("pointermove", move);
    target.addEventListener("pointerup", finish);
    target.addEventListener("pointercancel", finish);
  }

  /** Drag several selected elements together; a press without a drag picks the pressed one alone. */
  function dragGroup(a: Attached, node: PictureNode, down: PointerEvent, target: HTMLElement): void {
    const items = selection?.items ?? [node.id];
    const start = planPoint(a, down.clientX, down.clientY);
    const all = a.plan.picture?.nodes ?? [];
    const picked = items.map((id) => nodeOf(a, id)).filter((n): n is PictureNode => n !== undefined);
    // what is attached to a moving node, and the rest of a moving included picture, travels too
    const travelling = new Set<PictureNode>(picked);
    for (const n of picked) {
      for (const id of followersOf(n.id, all)) { const f = nodeOf(a, id); if (f !== undefined) travelling.add(f); }
      if (n.from != null) for (const other of all) if (other.from != null && other.from.cat === n.from.cat) travelling.add(other);
    }
    let last = { dx: 0, dy: 0 };
    let moved = false;
    const shiftAll = (dx: number, dy: number): void => { for (const n of travelling) shiftNode(a, n, dx, dy); };
    try { target.setPointerCapture(down.pointerId); } catch { /* synthetic input */ }
    const move = (event: PointerEvent): void => {
      const now = planPoint(a, event.clientX, event.clientY);
      const raw = { x: now.x - start.x, y: now.y - start.y };
      if (!moved && Math.hypot(raw.x, raw.y) * scaleOf(a) < 4) return;
      if (!moved) for (const bar of a.layer.querySelectorAll(".sb-style-bar")) bar.remove();
      moved = true;
      last = event.altKey ? { dx: raw.x, dy: raw.y } : { dx: toGrid(raw.x, 4), dy: toGrid(raw.y, 4) };
      shiftAll(last.dx, last.dy);
    };
    const finish = (event: PointerEvent): void => {
      target.removeEventListener("pointermove", move);
      target.removeEventListener("pointerup", finish);
      target.removeEventListener("pointercancel", finish);
      if (!moved && event.type !== "pointercancel") { select({ frame: a.plan.frame, item: node.id }); return; }
      const op = together(moveOps(a, items, () => last, last));
      if (event.type === "pointercancel" || op === null) { shiftAll(0, 0); styleBar(); return; }
      void run(a.plan.frame, op).then((result) => { if (!result.ok) { shiftAll(0, 0); styleBar(); } });
    };
    target.addEventListener("pointermove", move);
    target.addEventListener("pointerup", finish);
    target.addEventListener("pointercancel", finish);
  }

  /** Drag on the empty slide: everything the rectangle touches gets selected (Shift adds to what is). */
  function dragMarquee(a: Attached, down: PointerEvent): void {
    const start = planPoint(a, down.clientX, down.clientY);
    const keep = down.shiftKey && selection !== null && selection.frame === a.plan.frame ? [...selection.items] : [];
    const rect = doc.createElementNS(svgNamespace, "rect");
    rect.setAttribute("class", "sb-edit-marquee");
    let box: Box | null = null;
    try { a.slide.setPointerCapture(down.pointerId); } catch { /* synthetic input */ }
    const move = (event: PointerEvent): void => {
      const now = planPoint(a, event.clientX, event.clientY);
      if (box === null && Math.hypot(now.x - start.x, now.y - start.y) * scaleOf(a) < 4) return;
      if (box === null) a.marks.append(rect);
      box = { x: Math.min(start.x, now.x), y: Math.min(start.y, now.y), width: Math.abs(now.x - start.x), height: Math.abs(now.y - start.y) };
      for (const [k, v] of [["x", box.x], ["y", box.y], ["width", box.width], ["height", box.height]] as const) rect.setAttribute(k, String(v));
    };
    const finish = (event: PointerEvent): void => {
      a.slide.removeEventListener("pointermove", move);
      a.slide.removeEventListener("pointerup", finish);
      a.slide.removeEventListener("pointercancel", finish);
      rect.remove();
      if (box === null || event.type === "pointercancel") return;
      const area = box;
      const nodes = (a.plan.picture?.nodes ?? []).filter((n) => overlaps(n.box, area)).map((n) => n.id);
      // a line is taken when all of it lies inside
      const lines = (a.plan.picture?.lines ?? []).filter((l) => {
        const b = l.from != null ? null : lineBox(a, l.id);
        return b !== null && b.x >= area.x && b.y >= area.y && b.x + b.width <= area.x + area.width && b.y + b.height <= area.y + area.height;
      }).map((l) => l.id);
      selectMany(a.plan.frame, [...keep, ...lines, ...nodes]);
    };
    a.slide.addEventListener("pointermove", move);
    a.slide.addEventListener("pointerup", finish);
    a.slide.addEventListener("pointercancel", finish);
  }

  /** Turn a node about its centre with the handle above it: steps of 15 degrees, Alt for any angle. */
  function dragTurn(a: Attached, node: PictureNode, down: PointerEvent, handle: HTMLElement): void {
    const centre = centreOf(node);
    const before = rotationOf(node.options);
    let degrees = before;
    let moved = false;
    for (const bar of a.layer.querySelectorAll(".sb-style-bar")) bar.remove();
    try { handle.setPointerCapture(down.pointerId); } catch { /* synthetic input */ }
    const move = (event: PointerEvent): void => {
      const now = planPoint(a, event.clientX, event.clientY);
      if (Math.hypot(now.x - centre.x, now.y - centre.y) < 2) return;
      moved = true;
      // the handle sits straight above the centre when the node is not turned; the screen's y points down
      const raw = -(Math.atan2(now.y - centre.y, now.x - centre.x) * 180 / Math.PI + 90);
      degrees = normalDegrees(event.altKey ? Math.round(raw) : Math.round(raw / 15) * 15);
      poseNode(a, node, 0, 0, degrees);
    };
    const finish = (event: PointerEvent): void => {
      handle.removeEventListener("pointermove", move);
      handle.removeEventListener("pointerup", finish);
      handle.removeEventListener("pointercancel", finish);
      if (!moved || event.type === "pointercancel" || degrees === before) { poseNode(a, node, 0, 0); styleBar(); return; }
      void run(a.plan.frame, { kind: "style", item: node.id, set: degrees === 0 ? [] : [{ key: "rotate", value: String(degrees) }], remove: degrees === 0 ? ["rotate"] : [] })
        .then((result) => { if (!result.ok) { poseNode(a, node, 0, 0); styleBar(); } });
    };
    handle.addEventListener("pointermove", move);
    handle.addEventListener("pointerup", finish);
    handle.addEventListener("pointercancel", finish);
  }

  /** Drag an included picture: all its nodes travel together and the drop rewrites its shift. */
  function dragInclude(a: Attached, node: PictureNode, from: PictureFrom, down: PointerEvent, target: HTMLElement): void {
    const start = planPoint(a, down.clientX, down.clientY);
    const group = (a.plan.picture?.nodes ?? []).filter((n) => n.from != null && n.from.cat === from.cat);
    let last = { dx: 0, dy: 0 };
    let moved = false;
    const shiftAll = (dx: number, dy: number): void => { for (const n of group) shiftNode(a, n, dx, dy); };
    try { target.setPointerCapture(down.pointerId); } catch { /* synthetic input */ }
    const move = (event: PointerEvent): void => {
      const now = planPoint(a, event.clientX, event.clientY);
      const raw = { x: now.x - start.x, y: now.y - start.y };
      if (!moved && Math.hypot(raw.x, raw.y) * scaleOf(a) < 4) return;
      moved = true;
      last = event.altKey ? { dx: raw.x, dy: raw.y } : { dx: toGrid(raw.x, 8), dy: toGrid(raw.y, 8) };
      shiftAll(last.dx, last.dy);
    };
    const finish = (event: PointerEvent): void => {
      target.removeEventListener("pointermove", move);
      target.removeEventListener("pointerup", finish);
      target.removeEventListener("pointercancel", finish);
      if (!moved || event.type === "pointercancel" || (last.dx === 0 && last.dy === 0)) { shiftAll(0, 0); return; }
      void run(a.plan.frame, { kind: "move_include", item: from.cat, x: from.shift.x + last.dx, y: from.shift.y + last.dy }).then((result) => { if (!result.ok) shiftAll(0, 0); });
    };
    target.addEventListener("pointermove", move);
    target.addEventListener("pointerup", finish);
    target.addEventListener("pointercancel", finish);
    void node;
  }

  /** Resize from a corner: the box grows about its centre, as a node does in the source. */
  function dragResize(a: Attached, node: PictureNode, down: PointerEvent, handle: HTMLElement, target: HTMLElement): void {
    const centre = centreOf(node);
    const { width, height } = a.plan.size;
    let size = { w: node.box.width, h: node.box.height };
    let moved = false;
    for (const bar of a.layer.querySelectorAll(".sb-style-bar")) bar.remove();
    try { handle.setPointerCapture(down.pointerId); } catch { /* synthetic input */ }
    const paint = (w: number, h: number): void => {
      const x = centre.x - w / 2, y = centre.y - h / 2;
      for (const el of [target, ...a.slide.querySelectorAll<HTMLElement>(`.sb-item[data-item-id="${CSS.escape(`pic-${node.id}`)}"]`)]) {
        el.style.left = `${(x / width) * 100}%`; el.style.top = `${(y / height) * 100}%`;
        el.style.width = `${(w / width) * 100}%`; el.style.height = `${(h / height) * 100}%`;
      }
      const background = a.slide.querySelector(`[data-item-id="${CSS.escape(`pic-bg-${node.id}`)}"]`);
      if (background !== null) for (const [k, v] of [["x", x], ["y", y], ["width", w], ["height", h]] as const) background.setAttribute(k, String(v));
    };
    const move = (event: PointerEvent): void => {
      const now = planPoint(a, event.clientX, event.clientY);
      moved = true;
      // measured along the node's own sides, which a turned node does not share with the slide
      const turn = rotationOf(node.options) * Math.PI / 180;
      const [vx, vy] = [now.x - centre.x, now.y - centre.y];
      const own = { x: vx * Math.cos(turn) - vy * Math.sin(turn), y: vx * Math.sin(turn) + vy * Math.cos(turn) };
      size = { w: Math.max(16, toGrid(2 * Math.abs(own.x), 8)), h: Math.max(16, toGrid(2 * Math.abs(own.y), 8)) };
      paint(size.w, size.h);
    };
    const finish = (event: PointerEvent): void => {
      handle.removeEventListener("pointermove", move);
      handle.removeEventListener("pointerup", finish);
      handle.removeEventListener("pointercancel", finish);
      if (!moved || event.type === "pointercancel") { paint(node.box.width, node.box.height); styleBar(); return; }
      void run(a.plan.frame, { kind: "resize", node: node.id, width: size.w, height: size.h }).then((result) => {
        if (!result.ok) { paint(node.box.width, node.box.height); styleBar(); }
      });
    };
    handle.addEventListener("pointermove", move);
    handle.addEventListener("pointerup", finish);
    handle.addEventListener("pointercancel", finish);
  }

  function dragArrow(a: Attached, from: PictureNode, down: PointerEvent, handle: HTMLElement): void {
    const origin = centreOf(from);
    const rubber = doc.createElementNS(svgNamespace, "line");
    rubber.setAttribute("class", "sb-edit-rubber");
    rubber.setAttribute("x1", String(origin.x));
    rubber.setAttribute("y1", String(origin.y));
    rubber.setAttribute("x2", String(origin.x));
    rubber.setAttribute("y2", String(origin.y));
    a.marks.append(rubber);
    try { handle.setPointerCapture(down.pointerId); } catch { /* synthetic input */ }
    const under = (event: PointerEvent): string | null => {
      for (const el of doc.elementsFromPoint(event.clientX, event.clientY)) {
        const target = (el as Element).closest?.(".sb-node-target") as HTMLElement | null;
        if (target !== null && a.layer.contains(target) && target.dataset.node !== from.id) return target.dataset.node ?? null;
      }
      return null;
    };
    const move = (event: PointerEvent): void => {
      const now = planPoint(a, event.clientX, event.clientY);
      rubber.setAttribute("x2", String(now.x));
      rubber.setAttribute("y2", String(now.y));
      const over = under(event);
      for (const [id, el] of a.targets) el.classList.toggle("is-drop", id === over);
    };
    const finish = (event: PointerEvent): void => {
      handle.removeEventListener("pointermove", move);
      handle.removeEventListener("pointerup", finish);
      handle.removeEventListener("pointercancel", finish);
      rubber.remove();
      for (const el of a.targets.values()) el.classList.remove("is-drop");
      if (event.type === "pointercancel") return;
      const to = under(event);
      if (to !== null) { void run(a.plan.frame, { kind: "connect", from: from.id, to }); return; }
      // dropped on empty slide: offer a new element there, joined to this one
      const rect = a.slide.getBoundingClientRect();
      const inside = event.clientX >= rect.left && event.clientX <= rect.right && event.clientY >= rect.top && event.clientY <= rect.bottom;
      const far = Math.hypot(event.clientX - down.clientX, event.clientY - down.clientY) > 24;
      if (inside && far) openMenu(a, event.clientX, event.clientY, async (created) => { await run(a.plan.frame, { kind: "connect", from: from.id, to: created }); });
    };
    handle.addEventListener("pointermove", move);
    handle.addEventListener("pointerup", finish);
    handle.addEventListener("pointercancel", finish);
  }

  // --- keyboard -----------------------------------------------------------------------
  const typingElsewhere = (target: EventTarget | null): boolean => {
    const el = target as HTMLElement | null;
    return el !== null && typeof el.closest === "function" && el.closest("input, textarea, select, [contenteditable=''], [contenteditable='true'], .cm-editor") !== null;
  };
  /** The statements of what is selected, in the order they are written: what a copy takes. */
  function copyText(): string | null {
    if (selection === null || options.source === undefined) return null;
    const a = attached.get(selection.frame);
    if (a === undefined) return null;
    const spans = [...ownNodes(a, selection.items), ...ownLines(a, selection.items)].map((item) => item.span).sort((p, q) => p.start - q.start);
    const texts = spans.map((span) => options.source!(span)?.trim() ?? "").filter((t) => t !== "");
    return texts.length === 0 ? null : texts.join("\n");
  }
  const looksLikePicture = (text: string): boolean => /\\(node|draw)\b/.test(text);
  /** Add copied statements to a slide; each further paste on the same slide lands a little further on. */
  function paste(text: string, frame: string): void {
    if (copied === null || copied.text !== text) copied = { text, frame: "", pastes: new Map() };
    const count = (copied.pastes.get(frame) ?? (copied.frame === frame ? 0 : -1)) + 1;
    copied.pastes.set(frame, count);
    void run(frame, { kind: "paste", text, x: 16 * count, y: 16 * count }).then((result) => {
      if (result.ok && result.made !== undefined && result.made.length > 0) selectMany(frame, result.made);
    });
  }
  function removeSelected(): void {
    if (selection === null) return;
    const a = attached.get(selection.frame);
    if (a === undefined) return;
    // an included picture goes as a whole: its \\cat statement is what is removed
    const items = [...new Set(selection.items.map((id) => { const from = nodeOf(a, id)?.from; return from != null ? from.cat : id; }))];
    select(null);
    void run(a.plan.frame, items.length === 1 ? { kind: "delete", item: items[0]! } : { kind: "delete_many", items });
  }
  const activeFrame = (): string | null => selection?.frame ?? (lastFrame !== null && attached.has(lastFrame) ? lastFrame : null);

  const onKey = (event: KeyboardEvent): void => {
    if (event.key === "Escape" && menu !== null) { closeMenu(); return; }
    if (typingElsewhere(event.target) || editor !== null) return;
    if (event.ctrlKey || event.metaKey) {
      const key = event.key.toLowerCase();
      const frame = activeFrame();
      const a = frame === null ? undefined : attached.get(frame);
      if (a === undefined || event.altKey) return;
      if (key === "a") {
        const picture = a.plan.picture;
        selectMany(a.plan.frame, [...(picture?.lines ?? []).filter((l) => l.from == null).map((l) => l.id), ...(picture?.nodes ?? []).map((n) => n.id)]);
      } else if (key === "d") {
        const text = copyText();
        if (text === null) return;
        copied = { text, frame: a.plan.frame, pastes: copied !== null && copied.text === text ? copied.pastes : new Map() };
        paste(text, a.plan.frame);
      } else return;
      event.preventDefault();
      return;
    }
    if (selection === null) return;
    const a = attached.get(selection.frame);
    if (a === undefined) return;
    const several = selection.items.length > 1;
    const node = several ? undefined : nodeOf(a, selection.items[0]!);
    if (event.key === "Delete" || event.key === "Backspace") removeSelected();
    else if (event.key === "Escape") select(null);
    else if (event.key.startsWith("Arrow")) {
      const step = event.shiftKey ? 40 : 8;
      const dx = event.key === "ArrowLeft" ? -step : event.key === "ArrowRight" ? step : 0;
      const dy = event.key === "ArrowUp" ? -step : event.key === "ArrowDown" ? step : 0;
      const op = together(moveOps(a, selection.items, () => ({ dx, dy }), { dx, dy }));
      if (op === null) return;
      void run(a.plan.frame, op);
    }
    else if (node?.from != null) {
      if (event.key === "Enter") options.open?.(node.from.file);
      else return;
    }
    else if (node !== undefined && (event.key === "Enter" || event.key === "F2")) startTyping(a.plan.frame, node.id);
    else if (!several && lineOf(a, selection.items[0]!) !== undefined && (event.key === "Enter" || event.key === "F2")) {
      const line = lineOf(a, selection.items[0]!)!;
      startLabel(a.plan.frame, line.id, line.labels?.[0]?.index ?? 0);
    }
    else if (node !== undefined && event.key.length === 1 && !event.altKey) {
      // typing on a selected node starts replacing its text
      startTyping(a.plan.frame, node.id, true);
      return;
    } else return;
    event.preventDefault();
  };
  const onCopy = (event: ClipboardEvent): void => {
    if (typingElsewhere(event.target) || editor !== null || selection === null) return;
    const text = copyText();
    if (text === null) return;
    copied = { text, frame: selection.frame, pastes: new Map() };
    event.clipboardData?.setData("text/plain", text);
    event.preventDefault();
    const count = selection.items.length;
    if (event.type === "cut") removeSelected();
    options.status(`${event.type === "cut" ? "Cut" : "Copied"} ${count} element${count === 1 ? "" : "s"}`);
  };
  const onPaste = (event: ClipboardEvent): void => {
    if (typingElsewhere(event.target) || editor !== null) return;
    const frame = activeFrame();
    if (frame === null) return;
    const given = event.clipboardData?.getData("text/plain") ?? "";
    const text = looksLikePicture(given) ? given : given === "" && copied !== null ? copied.text : null;
    if (text === null) return;
    event.preventDefault();
    paste(text, frame);
  };
  const onDocPointer = (event: PointerEvent): void => {
    closeMenu();
    const el = event.target as HTMLElement | null;
    if (selection !== null && !event.shiftKey && (el === null || typeof el.closest !== "function" || el.closest(".sb-edit-layer") === null)) select(null);
  };
  doc.addEventListener("copy", onCopy);
  doc.addEventListener("cut", onCopy);
  doc.addEventListener("paste", onPaste);
  doc.addEventListener("keydown", onKey);
  doc.addEventListener("pointerdown", onDocPointer);

  return {
    attach(slide, plan) {
      const picture = plan.picture;
      if (picture === undefined) return () => undefined;
      const { width, height } = plan.size;
      const layer = doc.createElement("div");
      layer.className = "sb-layer sb-edit-layer";
      const marks = doc.createElementNS(svgNamespace, "svg") as SVGSVGElement;
      marks.setAttribute("class", "sb-layer sb-edit-marks");
      marks.setAttribute("viewBox", `0 0 ${width} ${height}`);
      marks.setAttribute("preserveAspectRatio", "none");
      layer.append(marks);
      const a: Attached = { slide, plan, layer, marks, targets: new Map(), labelShifts: new Map() };

      /** Shift+click adds an element to what is selected, or takes it out. */
      const toggleOrSelect = (frame: string, item: string, shift: boolean): void => {
        if (!shift || selection === null || selection.frame !== frame) { select({ frame, item }); return; }
        selectMany(frame, selection.items.includes(item) ? selection.items.filter((i) => i !== item) : [...selection.items, item]);
      };

      // lines first, so node targets lie above their ends
      for (const line of picture.lines) {
        if (line.from != null) continue;
        for (const painted of slide.querySelectorAll<SVGElement>(`.sb-layer-geometry [data-item-id^="${CSS.escape(`${line.item}-`)}"]`)) {
          const trail = painted.getAttribute("d");
          const hit: SVGElement = doc.createElementNS(svgNamespace, trail === null ? "line" : "path");
          hit.setAttribute("class", "sb-edit-line");
          hit.dataset.line = line.id;
          hit.dataset.segment = painted.getAttribute("data-item-id") ?? "";
          if (trail === null) for (const k of ["x1", "y1", "x2", "y2"]) hit.setAttribute(k, painted.getAttribute(k) ?? "0");
          else hit.setAttribute("d", trail);
          hit.addEventListener("dblclick", (event) => { event.stopPropagation(); startLabel(plan.frame, line.id, line.labels?.[0]?.index ?? 0); });
          hit.addEventListener("pointerdown", (event) => {
            if (event.button !== 0) return;
            event.stopPropagation();
            if (event.ctrlKey || event.metaKey) options.reveal?.(line.span);
            toggleOrSelect(plan.frame, line.id, event.shiftKey);
          });
          marks.append(hit);
        }
      }

      // a label is picked with its line; double-click types in it
      for (const line of picture.lines) {
        if (line.from != null) continue;
        for (const label of line.labels ?? []) {
          const target = doc.createElement("div");
          target.className = "sb-label-target";
          target.title = "Double-click to edit the label";
          target.style.left = `${(label.box.x / width) * 100}%`;
          target.style.top = `${(label.box.y / height) * 100}%`;
          target.style.width = `${(label.box.width / width) * 100}%`;
          target.style.height = `${(label.box.height / height) * 100}%`;
          target.addEventListener("pointerdown", (event) => { if (event.button !== 0) return; event.stopPropagation(); closeMenu(); editor?.close(true); toggleOrSelect(plan.frame, line.id, event.shiftKey); });
          target.addEventListener("dblclick", (event) => { event.stopPropagation(); startLabel(plan.frame, line.id, label.index); });
          layer.append(target);
        }
      }

      // an attached node shows a faint link to the node it follows
      for (const node of picture.nodes) {
        const to = node.attached === null ? undefined : (picture.nodes.find((n) => n.id === node.attached!.to) ?? picture.regions.find((r) => r.id === node.attached!.to));
        if (to === undefined) continue;
        const link = doc.createElementNS(svgNamespace, "line");
        link.setAttribute("class", "sb-edit-tether");
        const from = centreOf(node), end = { x: to.box.x + to.box.width / 2, y: to.box.y + to.box.height / 2 };
        for (const [k, v] of [["x1", from.x], ["y1", from.y], ["x2", end.x], ["y2", end.y]] as const) link.setAttribute(k, String(v));
        marks.append(link);
      }

      for (const node of picture.nodes) {
        const target = doc.createElement("div");
        target.className = "sb-node-target";
        target.dataset.node = node.id;
        target.tabIndex = 0;
        target.setAttribute("role", "button");
        target.setAttribute("aria-label", `Element: ${node.source.slice(0, 60)}${node.attached === null ? "" : `, attached ${node.attached.side} ${node.attached.to}`}`);
        target.style.left = `${(node.box.x / width) * 100}%`;
        target.style.top = `${(node.box.y / height) * 100}%`;
        target.style.width = `${(node.box.width / width) * 100}%`;
        target.style.height = `${(node.box.height / height) * 100}%`;
        if (rotationOf(node.options) !== 0) target.style.transform = `rotate(${-rotationOf(node.options)}deg)`;
        target.addEventListener("pointerdown", (event) => {
          if (event.button !== 0) return;
          event.stopPropagation();
          closeMenu();
          editor?.close(true);
          const from = node.from ?? null;
          if (event.ctrlKey || event.metaKey) { if (from !== null) options.open?.(from.file); else options.reveal?.(node.span); }
          if (event.shiftKey) { toggleOrSelect(plan.frame, node.id, true); return; }
          const current = attached.get(plan.frame);
          // pressing one of several selected elements drags them all
          if (current !== undefined && selection !== null && selection.frame === plan.frame && selection.items.length > 1 && selection.items.includes(node.id)) { dragGroup(current, node, event, target); return; }
          select({ frame: plan.frame, item: node.id });
          if (current === undefined) return;
          if (from !== null) dragInclude(current, node, from, event, target);
          else dragNode(current, node, event, target);
        });
        target.addEventListener("dblclick", (event) => {
          event.stopPropagation();
          if (node.from != null) options.open?.(node.from.file);
          else startTyping(plan.frame, node.id);
        });
        if (node.from != null) {
          target.classList.add("is-included");
          target.title = `From ${node.from.file}: drag to move the whole picture, double-click to open it`;
        }
        // an included node keeps its file's looks and size; a named one can still take arrows
        for (const side of node.from != null && !node.named ? [] : ["n", "e", "s", "w"]) {
          const handle = doc.createElement("span");
          handle.className = `sb-node-handle sb-node-handle-${side}`;
          handle.title = "Drag to another element to draw an arrow";
          handle.addEventListener("pointerdown", (event) => {
            if (event.button !== 0) return;
            event.stopPropagation();
            event.preventDefault();
            select({ frame: plan.frame, item: node.id });
            const current = attached.get(plan.frame);
            if (current !== undefined) dragArrow(current, node, event, handle);
          });
          target.append(handle);
        }
        for (const corner of node.from != null ? [] : ["nw", "ne", "sw", "se"]) {
          const grip = doc.createElement("span");
          grip.className = `sb-node-resize sb-node-resize-${corner}`;
          grip.title = "Drag to resize";
          grip.addEventListener("pointerdown", (event) => {
            if (event.button !== 0) return;
            event.stopPropagation();
            event.preventDefault();
            select({ frame: plan.frame, item: node.id });
            const current = attached.get(plan.frame);
            if (current !== undefined) dragResize(current, node, event, grip, target);
          });
          target.append(grip);
        }
        if (node.from == null) {
          const knob = doc.createElement("span");
          knob.className = "sb-node-turn";
          knob.title = "Drag to turn (Alt for any angle)";
          knob.addEventListener("pointerdown", (event) => {
            if (event.button !== 0) return;
            event.stopPropagation();
            event.preventDefault();
            select({ frame: plan.frame, item: node.id });
            const current = attached.get(plan.frame);
            if (current !== undefined) dragTurn(current, node, event, knob);
          });
          target.append(knob);
        }
        a.targets.set(node.id, target);
        layer.append(target);
      }

      const create = (event: MouseEvent): void => {
        if ((event.target as Element).closest?.(".sb-node-target, .sb-edit-line, .sb-node-editor, .sb-label-target, .sb-line-point") !== null) return;
        event.preventDefault();
        event.stopPropagation();
        const part = event.type === "dblclick" ? writtenAt(a, event) : null;
        if (part !== null) startWriting(plan.frame, part);
        else openMenu(a, event.clientX, event.clientY);
      };
      const press = (event: PointerEvent): void => {
        if (event.button !== 0 || (event.target as Element).closest?.(".sb-node-target, .sb-edit-line, .sb-node-editor, .sb-style-bar, .sb-label-target, .sb-line-point") != null) return;
        lastFrame = plan.frame;
        dragMarquee(a, event);
      };
      slide.addEventListener("dblclick", create);
      slide.addEventListener("contextmenu", create);
      slide.addEventListener("pointerdown", press);

      slide.append(layer);
      attached.set(plan.frame, a);
      if (selection !== null && selection.frame === plan.frame) selectMany(plan.frame, selection.items.filter((item) => nodeOf(a, item) !== undefined || lineOf(a, item) !== undefined));
      if (typeNext !== null && typeNext.frame === plan.frame && nodeOf(a, typeNext.node) !== undefined) startTyping(plan.frame, typeNext.node, true, typeNext.draft);
      else if (typeNext !== null && typeNext.frame === plan.frame && typeNext.node.startsWith("label:") && typeNext.draft !== undefined) {
        // a label being typed when the slide was repainted from elsewhere: it is typed on
        const [, index, ...rest] = typeNext.node.split(":");
        const carried = typeNext.draft;
        if (lineOf(a, rest.join(":")) !== undefined) startLabel(plan.frame, rest.join(":"), Number(index), false, carried);
      } else if (typeNext !== null && typeNext.frame === plan.frame && typeNext.node.startsWith("written:") && typeNext.draft !== undefined) startWriting(plan.frame, typeNext.node === "written:title" ? "title" : "body", typeNext.draft);
      return () => {
        // A repaint from elsewhere (a file changed on disk) must not eat what is being typed:
        // the text is carried over to the repainted slide.
        if (editor !== null && editor.frame === plan.frame) {
          typeNext = { frame: plan.frame, node: editor.node, draft: editor.draft() };
          editor.close(false);
        }
        slide.removeEventListener("dblclick", create);
        slide.removeEventListener("contextmenu", create);
        slide.removeEventListener("pointerdown", press);
        layer.remove();
        if (attached.get(plan.frame) === a) attached.delete(plan.frame);
      };
    },
    destroy() {
      closeMenu();
      doc.removeEventListener("keydown", onKey);
      doc.removeEventListener("copy", onCopy);
      doc.removeEventListener("cut", onCopy);
      doc.removeEventListener("paste", onPaste);
      doc.removeEventListener("pointerdown", onDocPointer);
    },
  };
}
