/**
 * The closed plan the web host paints: `slideblaster.session/1` section 5
 * (`docs/specs/session-v1-protocol.md`, lane I), mirrored here as TypeScript.
 *
 * Haskell owns everything in a plan: items, geometry, resolved colours, overlay
 * visibility, content trees. The host paints it, measures on request, runs KaTeX and
 * Shiki for `math`/`codeblock` content, and reports pointer/keyboard facts.
 *
 * Geometry is the session coordinate space: origin top-left, x right, y down, unit = one
 * slide pixel of the plan `size` (1280x720 for 16:9). Source spans live on the view, not
 * on plan items.
 */

import { isOutline } from "../ui/shape-library.ts";
export interface Box {
  readonly x: number;
  readonly y: number;
  readonly width: number;
  readonly height: number;
}

export interface Pt {
  readonly x: number;
  readonly y: number;
}

export interface Stroke {
  readonly color: string;
  readonly width: number;
  readonly dash?: readonly number[] | null;
}

export interface TextStyle {
  readonly font: string;
  readonly size: number;
  readonly weight: number | string;
  readonly italic: boolean;
  readonly color: string;
  readonly align: "left" | "center" | "right";
  readonly lineHeight: number;
}

export interface Hit {
  readonly nodeId: string;
}

export type Visibility = "visible" | "reserved";

/** Inline and block content: a closed tree; an unknown `t` is a host protocol error. */
export type Content =
  | {
      readonly t: "text"; readonly text: string; readonly bold?: boolean; readonly italic?: boolean; readonly mono?: boolean; readonly color?: string | null;
      /** Run path inside its node (optional additive field): lets the style toolbar address a selection. */
      readonly path?: readonly number[];
    }
  | { readonly t: "p" | "h1" | "h2" | "h3" | "h4" | "h5" | "h6" | "quote" | "ul" | "ol" | "li" | "strong" | "em" | "code" | "cite" | "footnote" | "u" | "s" | "mark"; readonly children: readonly Content[] }
  | { readonly t: "math"; readonly display: boolean; readonly tex: string; readonly label?: string }
  | { readonly t: "codeblock"; readonly language: string | null; readonly lines: readonly string[]; readonly highlight: readonly number[] | null }
  | { readonly t: "link"; readonly href: string; readonly children: readonly Content[] }
  | { readonly t: "table"; readonly head: readonly (readonly Cell[])[]; readonly body: readonly (readonly Cell[])[] }
  | { readonly t: "box"; readonly title: readonly Content[] | null; readonly fill: string; readonly titleFill: string; readonly children: readonly Content[] }
  | { readonly t: "columns"; readonly columns: readonly { readonly width: string; readonly children: readonly Content[] }[] }
  | { readonly t: "figure"; readonly fingerprint: string; readonly width: number; readonly height: number }
  | { readonly t: "drawing"; /** The figure's reference, and its file when it has one of its own. */ readonly ref: string; readonly file: string | null; readonly width: number; readonly height: number; /** Plan pixels to the centimetre. */ readonly scale: number; /** Where the drawing's top-left corner is in the picture: centimetres, y up. */ readonly origin: { readonly x: number; readonly y: number }; readonly items: readonly DrawingItem[] }
  | {
      readonly t: "image"; readonly src: string; readonly alt: string;
      /** Embedded project image (bytes in the plan so presenter windows and exports need no fetch); width/height are slide units. */
      readonly mime?: string; readonly bytesBase16?: string; readonly width?: number; readonly height?: number;
    }
  | { readonly t: "br" }
  | { readonly t: "vspace"; readonly em: number }
  | { readonly t: "reserved"; readonly children: readonly Content[] }
  | { readonly t: "colour"; readonly color: string; readonly children: readonly Content[] }
  | { readonly t: "route"; readonly route: string; readonly children: readonly Content[] }
  | { readonly t: "div"; readonly class?: string; readonly children: readonly Content[] }
  | { readonly t: "placeholder"; readonly state: PlaceholderState; readonly fingerprint?: string; readonly label: string }
  | { readonly t: "unsupported"; readonly label: string };

export interface Cell {
  readonly align: "l" | "c" | "r";
  readonly colspan?: number;
  readonly rowspan?: number;
  readonly children: readonly Content[];
}

export interface Artifact {
  readonly mime: string;
  readonly bytesBase16: string;
}

export type PlaceholderState = "pending" | "absent" | "error" | "stale";

export type Item =
  | {
      readonly kind: "rect";
      readonly id: string;
      readonly box: Box;
      readonly fill: string | null;
      readonly stroke: Stroke | null;
      readonly radius: number;
      readonly opacity: number;
      readonly hit: Hit | null;
      /** Degrees counter-clockwise about the box's centre. */
      readonly rotate?: number;
    }
  | {
      /** An outline stretched over `box`: `d` is path data in a unit box (x right, y down, 0 to 1). */
      readonly kind: "path";
      readonly id: string;
      readonly box: Box;
      readonly d: string;
      readonly fill: string | null;
      readonly stroke: Stroke | null;
      readonly opacity: number;
      readonly hit: Hit | null;
      readonly rotate?: number;
      /** The outline mirrored left-right (`x`) or top-bottom (`y`) within its box. */
      readonly flip?: { readonly x: boolean; readonly y: boolean };
    }
  | {
      readonly kind: "line";
      readonly id: string;
      readonly from: Pt;
      readonly to: Pt;
      readonly stroke: Stroke;
      readonly arrow: "none" | "end" | "start" | "both";
      /** The kind of head when the line names one (`-latex`, `-stealth`); a plain triangle otherwise. */
      readonly tip?: "latex" | "stealth";
      readonly hit: Hit | null;
    }
  | {
      /** A line that is not straight: `d` is path data in plan pixels, absolute `M`, `L` and `C` only. */
      readonly kind: "trail";
      readonly id: string;
      readonly d: string;
      readonly stroke: Stroke;
      readonly arrow: "none" | "end" | "start" | "both";
      /** The kind of head when the line names one (`-latex`, `-stealth`); a plain triangle otherwise. */
      readonly tip?: "latex" | "stealth";
      readonly hit: Hit | null;
    }
  | {
      readonly kind: "text";
      readonly id: string;
      readonly box: Box;
      readonly style: TextStyle;
      readonly content: readonly Content[];
      readonly visibility: Visibility;
    }
  | {
      readonly kind: "flow";
      readonly id: string;
      readonly box: Box;
      readonly style: TextStyle;
      readonly content: readonly Content[];
      readonly contentHash?: string;
      readonly rotate?: number;
    }
  | {
      readonly kind: "figure";
      readonly id: string;
      readonly box: Box;
      readonly fingerprint: string;
      readonly artifact: Artifact;
      readonly fit: "contain";
      readonly stale: boolean;
    }
  | {
      readonly kind: "image";
      readonly id: string;
      readonly box: Box;
      readonly resource: Artifact;
      readonly alt: string;
      readonly fit: string;
    }
  | {
      readonly kind: "placeholder";
      readonly id: string;
      readonly box: Box;
      readonly label: string;
      readonly state: PlaceholderState;
      readonly fingerprint?: string;
      readonly message?: string;
    };

export type AttachSide = "above" | "below" | "left" | "right" | "above left" | "above right" | "below left" | "below right";

/** A picture-tier node as the canvas edits it: geometry in plan pixels, content as written. */
export interface PictureNode {
  readonly id: string;
  readonly named: boolean;
  readonly box: Box;
  /** The authored `at (x,y)` point; for an attached node, its laid-out centre. */
  readonly at: { readonly x: number; readonly y: number };
  /** Set when the node is attached to a side of another (`below=of a`) and follows it. */
  readonly attached: { readonly side: AttachSide; readonly to: string; /** The written gap; null is the default one. */ readonly distance: number | null } | null;
  readonly source: string;
  /** The options as they apply (named styles stand for their options); a bare key has a null value. */
  readonly options: readonly PictureOption[];
  readonly span: { readonly start: number; readonly end: number };
  /** Set when the node comes from a picture file brought in with `\\cat`; its `span` then counts in that file. */
  readonly from?: PictureFrom | null;
}

/** Where an included item comes from: the file, the `\\cat` statement (`cat-N`, with its span in the deck) and its shift in plan pixels. */
export interface PictureFrom {
  readonly file: string;
  readonly cat: string;
  readonly span: { readonly start: number; readonly end: number };
  readonly shift: { readonly x: number; readonly y: number };
}

export interface PictureOption { readonly key: string; readonly value: string | null }

/** How a step of a line reaches its point. */
export type PictureJoin = "straight" | "hv" | "vh" | "bend left" | "bend right" | "curve";

/** A label on a line (`index` counts them as written, from 1), where it is painted, its text as written and its options. */
export interface PictureLabel { readonly index: number; readonly box: Box; readonly source: string; readonly options: readonly PictureOption[] }

/**
 * The points of a trail's path data: `M x y`, then `L x y` or `C x1 y1 x2 y2 x y`, all absolute.
 * Null when the text is anything else, so nothing but such a path is ever painted.
 */
export function trailPoints(d: unknown): { readonly command: "M" | "L" | "C"; readonly points: readonly Pt[] }[] | null {
  if (typeof d !== "string" || d.length > 4000) return null;
  const tokens = d.trim().split(/\s+/);
  const steps: { command: "M" | "L" | "C"; points: Pt[] }[] = [];
  let i = 0;
  while (i < tokens.length) {
    const command = tokens[i];
    if (command !== "M" && command !== "L" && command !== "C") return null;
    if ((command === "M") !== (steps.length === 0)) return null;
    const count = command === "C" ? 3 : 1;
    const points: Pt[] = [];
    for (let k = 0; k < count; k += 1) {
      const x = tokens[i + 1 + 2 * k], y = tokens[i + 2 + 2 * k];
      if (x === undefined || y === undefined || !/^-?\d+(\.\d+)?$/.test(x) || !/^-?\d+(\.\d+)?$/.test(y) || Math.abs(Number(x)) > 1e7 || Math.abs(Number(y)) > 1e7) return null;
      points.push({ x: Number(x), y: Number(y) });
    }
    steps.push({ command, points });
    i += 1 + 2 * count;
  }
  return steps.length >= 2 ? steps : null;
}

/** Path data from such steps. */
export const trailData = (steps: readonly { readonly command: string; readonly points: readonly Pt[] }[]): string =>
  steps.map((s) => `${s.command} ${s.points.map((p) => `${p.x} ${p.y}`).join(" ")}`).join(" ");

/** A picture-tier line: `item` prefixes its painted segments (`<item>-<k>`), `ends` are node ids or null for plain points. */
export interface PictureLine {
  readonly id: string;
  readonly item: string;
  readonly options: readonly PictureOption[];
  readonly ends: readonly (string | null)[];
  /** For each end or corner: its written point in plan pixels, or null where it is a node. */
  readonly points?: readonly (Pt | null)[];
  /** How each step goes; one fewer than `ends`. */
  readonly joins?: readonly PictureJoin[];
  /** The bend of a bent line in degrees, when it has one. */
  readonly bend?: number | null;
  readonly labels?: readonly PictureLabel[];
  readonly span: { readonly start: number; readonly end: number };
  readonly from?: PictureFrom | null;
}

/** A piece of a slide's ordinary text: its byte span in the deck and exact source. An empty span
 * is where text would go; `before` and `after` then separate it from what is around it. */
export interface WrittenText {
  readonly part: "title" | "body";
  readonly span: { readonly start: number; readonly end: number };
  readonly source: string;
  readonly before: string;
  readonly after: string;
}

export interface Plan {
  readonly protocol: "slideblaster.session/1";
  readonly frame: string;
  readonly surface: "audience" | "notes";
  readonly step: number;
  readonly steps: number;
  readonly revision: number;
  readonly ticket: number;
  readonly session?: number;
  readonly coordinateSpace: "slide_y_down";
  readonly size: { readonly width: number; readonly height: number };
  readonly background: { readonly fill: string };
  readonly items: readonly Item[];
  /** Ready figure artifacts of this frame by fingerprint (resolves inline `figure` content). */
  readonly artifacts?: Readonly<Record<string, Artifact>>;
  /** The slide's own title and body text as written, for typing on the slide (same slides as `picture`). */
  readonly written?: readonly WrittenText[];
  /** Present on slides that take canvas edits (the deck's own slides, audience side). */
  readonly picture?: {
    readonly nodes: readonly PictureNode[];
    readonly lines: readonly PictureLine[];
    /** Default gap between a node and one attached to it. */
    readonly distance: number;
    /** The slide's own title and body, which nodes can attach to but which are not picture nodes. */
    readonly regions: readonly { readonly id: string; readonly box: Box }[];
  };
}

export class PlanError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "PlanError";
  }
}

const contentContainers = new Set(["u", "s", "mark", "p", "h1", "h2", "h3", "h4", "h5", "h6", "quote", "ul", "ol", "li", "strong", "em", "code", "cite", "footnote"]);
const maxDepth = 32;
const maxNodes = 50_000;
const colourPattern = /^(#[0-9a-fA-F]{3,8}|rgba?\([0-9., %]+\)|transparent)$/;

/** Boundary check for one plan: throws `PlanError` naming the first offending path. */
export function validatePlan(value: unknown, path = "plan"): Plan {
  const plan = obj(value, path);
  oneOf(plan.surface, ["audience", "notes"], `${path}.surface`);
  str(plan.frame, `${path}.frame`);
  uint(plan.step, `${path}.step`);
  uint(plan.steps, `${path}.steps`);
  uint(plan.revision, `${path}.revision`);
  uint(plan.ticket, `${path}.ticket`);
  if (plan.coordinateSpace !== "slide_y_down") fail(`${path}.coordinateSpace`, "expected slide_y_down");
  const size = obj(plan.size, `${path}.size`);
  positive(size.width, `${path}.size.width`);
  positive(size.height, `${path}.size.height`);
  colour(obj(plan.background, `${path}.background`).fill, `${path}.background.fill`);
  const budget = { nodes: 0 };
  arr(plan.items, `${path}.items`).forEach((item, i) => validateItem(item, `${path}.items[${i}]`, budget));
  if (plan.artifacts !== undefined) for (const [fp, a] of Object.entries(obj(plan.artifacts, `${path}.artifacts`))) artifact(a, `${path}.artifacts.${fp}`);
  return plan as unknown as Plan;
}

function validateItem(value: unknown, path: string, budget: { nodes: number }): void {
  const item = obj(value, path);
  const kind = str(item.kind, `${path}.kind`);
  str(item.id, `${path}.id`);
  switch (kind) {
    case "rect":
      box(item.box, `${path}.box`);
      if (item.fill !== null) colour(item.fill, `${path}.fill`);
      if (item.stroke !== null) stroke(item.stroke, `${path}.stroke`);
      finite(item.radius, `${path}.radius`);
      finite(item.opacity, `${path}.opacity`);
      if (item.rotate !== undefined) finite(item.rotate, `${path}.rotate`);
      return;
    case "path":
      box(item.box, `${path}.box`);
      if (!isOutline(item.d)) fail(`${path}.d`, "expected outline path data (M L Q C A Z and numbers)");
      if (item.fill !== null) colour(item.fill, `${path}.fill`);
      if (item.stroke !== null) stroke(item.stroke, `${path}.stroke`);
      finite(item.opacity, `${path}.opacity`);
      if (item.rotate !== undefined) finite(item.rotate, `${path}.rotate`);
      if (item.flip !== undefined) {
        const flip = obj(item.flip, `${path}.flip`);
        if (typeof flip.x !== "boolean" || typeof flip.y !== "boolean") fail(`${path}.flip`, "expected x and y booleans");
      }
      return;
    case "line":
      pt(item.from, `${path}.from`);
      pt(item.to, `${path}.to`);
      stroke(item.stroke, `${path}.stroke`);
      oneOf(item.arrow, ["none", "end", "start", "both"], `${path}.arrow`);
      return;
    case "trail":
      if (trailPoints(item.d) === null) fail(`${path}.d`, "expected path data in plan pixels (M, L and C with numbers)");
      stroke(item.stroke, `${path}.stroke`);
      oneOf(item.arrow, ["none", "end", "start", "both"], `${path}.arrow`);
      return;
    case "text":
    case "flow":
      box(item.box, `${path}.box`);
      textStyle(item.style, `${path}.style`);
      if (kind === "text") oneOf(item.visibility, ["visible", "reserved"], `${path}.visibility`);
      if (item.rotate !== undefined) finite(item.rotate, `${path}.rotate`);
      arr(item.content, `${path}.content`).forEach((c, i) => validateContent(c, `${path}.content[${i}]`, 0, budget));
      return;
    case "figure":
      box(item.box, `${path}.box`);
      str(item.fingerprint, `${path}.fingerprint`);
      artifact(item.artifact, `${path}.artifact`);
      return;
    case "image":
      box(item.box, `${path}.box`);
      artifact(item.resource, `${path}.resource`);
      return;
    case "placeholder":
      box(item.box, `${path}.box`);
      str(item.label, `${path}.label`);
      oneOf(item.state, ["pending", "absent", "error", "stale"], `${path}.state`);
      return;
    default:
      fail(`${path}.kind`, `unknown item kind ${kind}`);
  }
}

export function validateContent(value: unknown, path: string, depth: number, budget: { nodes: number }): void {
  if (depth > maxDepth) fail(path, "content nests too deeply");
  if (++budget.nodes > maxNodes) fail(path, "plan has too many content nodes");
  const node = obj(value, path);
  const t = str(node.t, `${path}.t`);
  const kids = (v: unknown, p: string) => arr(v, p).forEach((c, i) => validateContent(c, `${p}[${i}]`, depth + 1, budget));
  if (contentContainers.has(t)) return kids(node.children, `${path}.children`);
  switch (t) {
    case "text": str(node.text, `${path}.text`); return;
    case "math": str(node.tex, `${path}.tex`); if (typeof node.display !== "boolean") fail(`${path}.display`, "expected boolean"); return;
    case "codeblock": arr(node.lines, `${path}.lines`).forEach((l, i) => str(l, `${path}.lines[${i}]`)); return;
    case "link": str(node.href, `${path}.href`); return kids(node.children, `${path}.children`);
    case "table":
      for (const part of ["head", "body"] as const) {
        arr(node[part], `${path}.${part}`).forEach((row, i) =>
          arr(row, `${path}.${part}[${i}]`).forEach((cell, j) =>
            kids(obj(cell, `${path}.${part}[${i}][${j}]`).children, `${path}.${part}[${i}][${j}].children`)));
      }
      return;
    case "box":
      colour(node.fill, `${path}.fill`);
      colour(node.titleFill, `${path}.titleFill`);
      if (node.title !== null) kids(node.title, `${path}.title`);
      return kids(node.children, `${path}.children`);
    case "columns":
      arr(node.columns, `${path}.columns`).forEach((c, i) => {
        const column = obj(c, `${path}.columns[${i}]`);
        str(column.width, `${path}.columns[${i}].width`);
        kids(column.children, `${path}.columns[${i}].children`);
      });
      return;
    case "figure": str(node.fingerprint, `${path}.fingerprint`); return;
    case "drawing":
      finite(node.width, `${path}.width`);
      finite(node.height, `${path}.height`);
      arr(node.items, `${path}.items`).forEach((raw, i) => {
        const item = obj(raw, `${path}.items[${i}]`);
        str(item.id, `${path}.items[${i}].id`);
        oneOf(item.k, ["path", "node"], `${path}.items[${i}].k`);
        if (item.k === "path") str(item.d, `${path}.items[${i}].d`);
        else kids(item.content, `${path}.items[${i}].content`);
      });
      return;
    case "image": str(node.src, `${path}.src`); return;
    case "colour": colour(node.color, `${path}.color`); return kids(node.children, `${path}.children`);
    case "div": return kids(node.children, `${path}.children`);
    case "placeholder": str(node.label, `${path}.label`); oneOf(node.state, ["pending", "absent", "error", "stale"], `${path}.state`); return;
    case "unsupported": str(node.label, `${path}.label`); return;
    case "br": return;
    case "vspace": finite(node.em, `${path}.em`); return;
    case "reserved": return kids(node.children, `${path}.children`);
    case "route": str(node.route, `${path}.route`); return kids(node.children, `${path}.children`);
    default: fail(`${path}.t`, `unknown content kind ${t}`);
  }
}

function fail(path: string, message: string): never { throw new PlanError(`${path}: ${message}`); }
function obj(v: unknown, path: string): Record<string, unknown> {
  if (typeof v !== "object" || v === null || Array.isArray(v)) fail(path, "expected object");
  return v as Record<string, unknown>;
}
function arr(v: unknown, path: string): unknown[] { if (!Array.isArray(v)) fail(path, "expected array"); return v; }
function str(v: unknown, path: string): string { if (typeof v !== "string") fail(path, "expected string"); return v; }
function uint(v: unknown, path: string): void { if (typeof v !== "number" || !Number.isSafeInteger(v) || v < 0) fail(path, "expected non-negative integer"); }
function positive(v: unknown, path: string): void { if (typeof v !== "number" || !Number.isFinite(v) || v <= 0) fail(path, "expected positive number"); }
function finite(v: unknown, path: string): void { if (typeof v !== "number" || !Number.isFinite(v) || Math.abs(v) > 1e7) fail(path, "expected bounded number"); }
function oneOf(v: unknown, allowed: readonly string[], path: string): void { if (typeof v !== "string" || !allowed.includes(v)) fail(path, `expected one of ${allowed.join(", ")}`); }
function colour(v: unknown, path: string): void { if (typeof v !== "string" || !colourPattern.test(v)) fail(path, "expected a resolved colour"); }
function box(v: unknown, path: string): void {
  const b = obj(v, path);
  for (const key of ["x", "y", "width", "height"]) finite(b[key], `${path}.${key}`);
  if ((b.width as number) < 0 || (b.height as number) < 0) fail(path, "negative size");
}
function pt(v: unknown, path: string): void { const p = obj(v, path); finite(p.x, `${path}.x`); finite(p.y, `${path}.y`); }
function stroke(v: unknown, path: string): void { const s = obj(v, path); colour(s.color, `${path}.color`); finite(s.width, `${path}.width`); }
function textStyle(v: unknown, path: string): void {
  const s = obj(v, path);
  str(s.font, `${path}.font`);
  finite(s.size, `${path}.size`);
  colour(s.color, `${path}.color`);
  oneOf(s.align, ["left", "center", "right"], `${path}.align`);
  finite(s.lineHeight, `${path}.lineHeight`);
}
function artifact(v: unknown, path: string): void {
  const a = obj(v, path);
  str(a.mime, `${path}.mime`);
  if (typeof a.bytesBase16 !== "string" || !/^(?:[0-9a-f]{2})*$/.test(a.bytesBase16)) fail(`${path}.bytesBase16`, "expected lowercase base16");
}

/** A part of a TikZ figure the core carried out itself. Lengths are plan pixels from the drawing's top-left corner; `span` is the statement in the figure's text. */
export type DrawingItem =
  | {
      readonly k: "path"; readonly id: string; readonly span: readonly [number, number];
      /** What an edit names: where the statement (or, for a node's outline, the node) starts. */
      readonly at: number;
      /** Set on the outline of a node: the id of that node. */
      readonly of?: string;
      readonly d: string;
      readonly stroke: { readonly color: string; readonly width: number; readonly dash: readonly number[] } | null;
      readonly fill: string | null;
      readonly tips: { readonly start: DrawingTip | null; readonly end: DrawingTip | null };
      readonly opacity: number;
      /** Offsets and softness in plan pixels (y down), darkness from 0 to 1. */
      readonly shadow?: { readonly dx: number; readonly dy: number; readonly blur: number; readonly opacity: number } | null;
      readonly rotate?: number;
      readonly about?: { readonly x: number; readonly y: number };
    }
  | {
      readonly k: "node"; readonly id: string; readonly span: readonly [number, number];
      readonly at: number;
      /** The node within its statement, and its text between the braces. */
      readonly node: readonly [number, number]; readonly text: readonly [number, number];
      readonly name: string | null;
      readonly box: Box;
      readonly rotate: number; readonly opacity: number;
      readonly color: string; readonly size: number; readonly bold: boolean; readonly italic: boolean; readonly mono: boolean; readonly align: string;
      /** Whether the text is broken at the node's text width. */
      readonly wrap: boolean;
      readonly source: string;
      /** What the size of the text depends on: the page reports the measured size under this key. */
      readonly key: string;
      readonly content: readonly Content[];
    };

/** An arrow head: its kind, its length in plan pixels, whether it is hollow. */
export interface DrawingTip { readonly kind: "to" | "latex" | "stealth" | "triangle" | "bar" | "circle" | "diamond" | "square"; readonly length: number; readonly open: boolean }
