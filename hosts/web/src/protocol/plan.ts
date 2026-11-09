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
    }
  | {
      readonly kind: "line";
      readonly id: string;
      readonly from: Pt;
      readonly to: Pt;
      readonly stroke: Stroke;
      readonly arrow: "none" | "end" | "both";
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
      return;
    case "line":
      pt(item.from, `${path}.from`);
      pt(item.to, `${path}.to`);
      stroke(item.stroke, `${path}.stroke`);
      oneOf(item.arrow, ["none", "end", "both"], `${path}.arrow`);
      return;
    case "text":
    case "flow":
      box(item.box, `${path}.box`);
      textStyle(item.style, `${path}.style`);
      if (kind === "text") oneOf(item.visibility, ["visible", "reserved"], `${path}.visibility`);
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
