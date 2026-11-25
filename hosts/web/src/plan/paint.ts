/**
 * Plan painter: one session/1 `Plan` becomes layered DOM.
 *
 *   .sb-slide                      aspect-ratio box, container for `cqw` units
 *     svg.sb-layer-geometry        rect + line items (picture tier geometry, arrows)
 *     div.sb-layer-content         text / flow / figure / image / placeholder items (HTML)
 *     div.sb-layer-overlay         interaction targets for items that carry a `hit`
 *
 * Painting is mechanical: positions, sizes and colours come from the plan; the painter
 * adds no layout policy. Math and code go through host content providers; when a provider
 * is absent the block shows a labelled placeholder and the slide still paints. Everything
 * painted is built with DOM APIs (no string HTML) except KaTeX output and sanitised SVG.
 */
import type { DrawingTip, Artifact, Box, Content, Item, Plan, PlaceholderState } from "../protocol/plan.ts";
import type { MathProvider } from "../content/math.ts";
import type { CodeHighlighter, HighlightToken } from "../content/highlight.ts";
import { bytesFromBase16 } from "../protocol/product-v2.ts";
import { sanitizeSvg } from "./svg-sanitize.ts";

const svgNamespace = "http://www.w3.org/2000/svg";
let slideCounter = 0;

export interface PaintContext {
  readonly doc: Document;
  readonly math?: MathProvider | null;
  readonly highlighter?: CodeHighlighter | null;
  /** Resolve a project-relative image path to a loadable URL, or null when unavailable. */
  readonly resolveAsset?: ((src: string) => string | null) | null;
  /** Interaction targets are created only when true (the active, acknowledged surface). */
  readonly interactive?: boolean;
  readonly selection?: string | null;
}

export interface PaintedSlide {
  readonly element: HTMLElement;
  /** Resolves when asynchronous enrichment (syntax highlighting) has been applied. */
  readonly settled: Promise<void>;
}

export function paintPlan(plan: Plan, ctx: PaintContext): PaintedSlide {
  const { doc } = ctx;
  const uid = `sb${(slideCounter += 1)}`;
  const pending: Promise<void>[] = [];
  const width = plan.size.width;
  const height = plan.size.height;
  const root = doc.createElement("div");
  root.className = "sb-slide";
  root.dataset.frame = plan.frame;
  root.dataset.surface = plan.surface;
  root.dataset.step = String(plan.step);
  root.dataset.steps = String(plan.steps);
  root.dataset.revision = String(plan.revision);
  root.dataset.ticket = String(plan.ticket);
  root.style.setProperty("--sb-w", String(width));
  root.style.setProperty("--sb-unit", `calc(100cqw / ${width})`);
  root.style.aspectRatio = `${width} / ${height}`;
  root.style.background = plan.background.fill;

  const newGeometry = (): SVGElement => {
    const svg = doc.createElementNS(svgNamespace, "svg");
    svg.setAttribute("class", "sb-layer sb-layer-geometry");
    svg.setAttribute("viewBox", `0 0 ${width} ${height}`);
    svg.setAttribute("preserveAspectRatio", "none");
    svg.setAttribute("aria-hidden", "true");
    return svg;
  };
  const newContent = (): HTMLElement => { const div = doc.createElement("div"); div.className = "sb-layer sb-layer-content"; return div; };
  const first = newGeometry();
  let geometry = first;
  let content = newContent();
  const layers: Element[] = [geometry, content];
  // Shapes are drawn under text. A picture node painted after another one's text, and over
  // it, starts a new pair of layers, so that later nodes cover earlier ones as written.
  let texts: Box[] = [];
  const above = (box: Box): void => {
    if (!texts.some((t) => t.x < box.x + box.width && box.x < t.x + t.width && t.y < box.y + box.height && box.y < t.y + t.height)) return;
    geometry = newGeometry();
    content = newContent();
    layers.push(geometry, content);
    texts = [];
  };
  const turn = (box: Box, degrees: number | undefined): string | null =>
    degrees === undefined || degrees === 0 ? null : `rotate(${-degrees} ${box.x + box.width / 2} ${box.y + box.height / 2})`;
  const overlay = doc.createElement("div");
  overlay.className = "sb-layer sb-layer-overlay";

  const figuresByFingerprint = new Map<string, Extract<Item, { kind: "figure" }>>();
  for (const item of plan.items) if (item.kind === "figure") figuresByFingerprint.set(item.fingerprint, item);

  const painter = makeContentPainter(ctx, figuresByFingerprint, pending, plan.artifacts ?? {});
  const defs = doc.createElementNS(svgNamespace, "defs");
  first.append(defs);
  const markers = new Map<string, string>();
  const marker = (color: string, end: "start" | "end", tip?: "latex" | "stealth"): string => {
    const key = `${end}${color}${tip ?? ""}`;
    let id = markers.get(key);
    if (id === undefined) {
      id = `${uid}-m${markers.size}`;
      markers.set(key, id);
      const m = doc.createElementNS(svgNamespace, "marker");
      m.setAttribute("id", id);
      m.setAttribute("markerWidth", "10");
      m.setAttribute("markerHeight", "10");
      m.setAttribute("refX", end === "end" ? "9" : "1");
      m.setAttribute("refY", "5");
      m.setAttribute("orient", "auto");
      m.setAttribute("markerUnits", "userSpaceOnUse");
      const path = doc.createElementNS(svgNamespace, "path");
      // the plain head is a triangle; LaTeX's has hollowed sides, a stealth head a notch at its back
      const heads = {
        plain: ["M0,0 L10,5 L0,10 z", "M10,0 L0,5 L10,10 z"],
        latex: ["M0,1.2 C3,3.5 7,4.7 10,5 C7,5.3 3,6.5 0,8.8 z", "M10,1.2 C7,3.5 3,4.7 0,5 C3,5.3 7,6.5 10,8.8 z"],
        stealth: ["M0,0.5 L10,5 L0,9.5 L3.2,5 z", "M10,0.5 L0,5 L10,9.5 L6.8,5 z"],
      } as const;
      path.setAttribute("d", heads[tip ?? "plain"][end === "end" ? 0 : 1]);
      path.setAttribute("fill", color);
      m.append(path);
      defs.append(m);
    }
    return id;
  };

  for (const item of plan.items) {
    switch (item.kind) {
      case "rect": {
        if (item.id.startsWith("pic-bg-")) above(item.box);
        const rect = doc.createElementNS(svgNamespace, "rect");
        const turned = turn(item.box, item.rotate);
        if (turned !== null) rect.setAttribute("transform", turned);
        rect.setAttribute("class", "sb-rect");
        rect.setAttribute("data-item-id", item.id);
        rect.setAttribute("x", String(item.box.x));
        rect.setAttribute("y", String(item.box.y));
        rect.setAttribute("width", String(item.box.width));
        rect.setAttribute("height", String(item.box.height));
        if (item.radius > 0) { rect.setAttribute("rx", String(item.radius)); rect.setAttribute("ry", String(item.radius)); }
        rect.setAttribute("fill", item.fill ?? "none");
        if (item.stroke !== null) {
          rect.setAttribute("stroke", item.stroke.color);
          rect.setAttribute("stroke-width", String(item.stroke.width));
          if (item.stroke.dash) rect.setAttribute("stroke-dasharray", item.stroke.dash.join(" "));
        }
        rect.setAttribute("opacity", String(item.opacity));
        geometry.append(rect);
        if (item.hit !== null && ctx.interactive === true) overlay.append(hitTarget(doc, item.box, item.hit.nodeId, item.id, plan, ctx.selection));
        break;
      }
      case "path": {
        // the unit-box outline stretched over the node's box; the stroke keeps its own width
        if (item.id.startsWith("pic-bg-")) above(item.box);
        const holder = doc.createElementNS(svgNamespace, "g");
        holder.setAttribute("class", "sb-turn");
        const turned = turn(item.box, item.rotate);
        if (turned !== null) holder.setAttribute("transform", turned);
        const frame = doc.createElementNS(svgNamespace, "svg");
        frame.setAttribute("class", "sb-outline");
        frame.setAttribute("data-item-id", item.id);
        frame.setAttribute("x", String(item.box.x));
        frame.setAttribute("y", String(item.box.y));
        frame.setAttribute("width", String(Math.max(item.box.width, 0.01)));
        frame.setAttribute("height", String(Math.max(item.box.height, 0.01)));
        frame.setAttribute("viewBox", "0 0 1 1");
        frame.setAttribute("preserveAspectRatio", "none");
        frame.setAttribute("overflow", "visible");
        frame.setAttribute("opacity", String(item.opacity));
        const outline = doc.createElementNS(svgNamespace, "path");
        outline.setAttribute("d", item.d);
        if (item.flip !== undefined && (item.flip.x || item.flip.y)) outline.setAttribute("transform", `translate(${item.flip.x ? 1 : 0} ${item.flip.y ? 1 : 0}) scale(${item.flip.x ? -1 : 1} ${item.flip.y ? -1 : 1})`);
        outline.setAttribute("fill", item.fill ?? "none");
        outline.setAttribute("vector-effect", "non-scaling-stroke");
        outline.setAttribute("stroke-linejoin", "round");
        if (item.stroke !== null) {
          outline.setAttribute("stroke", item.stroke.color);
          outline.setAttribute("stroke-width", String(item.stroke.width));
          if (item.stroke.dash) outline.setAttribute("stroke-dasharray", item.stroke.dash.join(" "));
        }
        frame.append(outline);
        holder.append(frame);
        geometry.append(holder);
        if (item.hit !== null && ctx.interactive === true) overlay.append(hitTarget(doc, item.box, item.hit.nodeId, item.id, plan, ctx.selection));
        break;
      }
      case "line": {
        const line = doc.createElementNS(svgNamespace, "line");
        line.setAttribute("class", "sb-line-item");
        line.setAttribute("data-item-id", item.id);
        line.setAttribute("x1", String(item.from.x));
        line.setAttribute("y1", String(item.from.y));
        line.setAttribute("x2", String(item.to.x));
        line.setAttribute("y2", String(item.to.y));
        line.setAttribute("stroke", item.stroke.color);
        line.setAttribute("stroke-width", String(item.stroke.width));
        if (item.stroke.dash) line.setAttribute("stroke-dasharray", item.stroke.dash.join(" "));
        if (item.arrow === "end" || item.arrow === "both") line.setAttribute("marker-end", `url(#${marker(item.stroke.color, "end", item.tip)})`);
        if (item.arrow === "start" || item.arrow === "both") line.setAttribute("marker-start", `url(#${marker(item.stroke.color, "start", item.tip)})`);
        geometry.append(line);
        if (item.hit !== null && ctx.interactive === true) {
          const pad = Math.max(10, item.stroke.width * 3);
          const box: Box = {
            x: Math.min(item.from.x, item.to.x) - pad, y: Math.min(item.from.y, item.to.y) - pad,
            width: Math.abs(item.from.x - item.to.x) + 2 * pad, height: Math.abs(item.from.y - item.to.y) + 2 * pad,
          };
          overlay.append(hitTarget(doc, box, item.hit.nodeId, item.id, plan, ctx.selection));
        }
        break;
      }
      case "trail": {
        const trail = doc.createElementNS(svgNamespace, "path");
        trail.setAttribute("class", "sb-line-item sb-trail");
        trail.setAttribute("data-item-id", item.id);
        trail.setAttribute("d", item.d);
        trail.setAttribute("fill", "none");
        trail.setAttribute("stroke-linejoin", "round");
        trail.setAttribute("stroke", item.stroke.color);
        trail.setAttribute("stroke-width", String(item.stroke.width));
        if (item.stroke.dash) trail.setAttribute("stroke-dasharray", item.stroke.dash.join(" "));
        if (item.arrow === "end" || item.arrow === "both") trail.setAttribute("marker-end", `url(#${marker(item.stroke.color, "end", item.tip)})`);
        if (item.arrow === "start" || item.arrow === "both") trail.setAttribute("marker-start", `url(#${marker(item.stroke.color, "start", item.tip)})`);
        geometry.append(trail);
        break;
      }
      case "text":
      case "flow": {
        const box = placed(doc, item.box, width, height, `sb-item sb-${item.kind}`, item.id);
        const st = item.style;
        box.style.fontFamily = st.font;
        box.style.fontSize = `calc(var(--sb-unit) * ${st.size})`;
        box.style.fontWeight = String(st.weight);
        box.style.fontStyle = st.italic ? "italic" : "normal";
        box.style.color = st.color;
        box.style.textAlign = st.align;
        box.style.lineHeight = String(st.lineHeight);
        if (item.kind === "text" && item.visibility === "reserved") box.style.visibility = "hidden";
        if (item.kind === "flow" && item.rotate !== undefined && item.rotate !== 0) box.style.transform = `rotate(${-item.rotate}deg)`;
        if (item.id.startsWith("pic-")) texts.push(item.box);
        painter.children(item.content, box);
        content.append(box);
        break;
      }
      case "figure": {
        const box = placed(doc, item.box, width, height, "sb-item sb-figure-item", item.id);
        box.dataset.fingerprint = item.fingerprint;
        box.dataset.status = item.stale ? "stale" : "compiled";
        const inner = painter.artifact(item.artifact.mime, item.artifact.bytesBase16, item.id);
        box.append(inner, badge(doc, item.stale ? "stale" : "compiled", item.stale ? "stale" : "compiled"));
        content.append(box);
        break;
      }
      case "image": {
        const box = placed(doc, item.box, width, height, "sb-item sb-image-item", item.id);
        box.append(painter.artifact(item.resource.mime, item.resource.bytesBase16, item.id, item.alt));
        content.append(box);
        break;
      }
      case "placeholder": {
        const box = placed(doc, item.box, width, height, `sb-item sb-placeholder-item sb-state-${item.state}`, item.id);
        box.dataset.state = item.state;
        if (item.fingerprint !== undefined) box.dataset.fingerprint = item.fingerprint;
        box.append(placeholderBody(doc, item.label, item.state, item.message));
        content.append(box);
        break;
      }
    }
  }
  root.append(...layers, overlay);
  return { element: root, settled: Promise.all(pending).then(() => undefined) };
}

function placed(doc: Document, box: Box, width: number, height: number, className: string, id: string): HTMLElement {
  const element = doc.createElement("div");
  element.className = className;
  element.dataset.itemId = id;
  element.setAttribute("data-node-id", id);
  element.style.left = `${(box.x / width) * 100}%`;
  element.style.top = `${(box.y / height) * 100}%`;
  element.style.width = `${(box.width / width) * 100}%`;
  element.style.height = `${(box.height / height) * 100}%`;
  return element;
}

function hitTarget(doc: Document, box: Box, nodeId: string, itemId: string, plan: Plan, selection: string | null | undefined): HTMLElement {
  const target = doc.createElement("button");
  target.type = "button";
  target.className = "sb-hit";
  target.dataset.nodeId = nodeId;
  target.dataset.itemId = itemId;
  target.style.left = `${(box.x / plan.size.width) * 100}%`;
  target.style.top = `${(box.y / plan.size.height) * 100}%`;
  target.style.width = `${(box.width / plan.size.width) * 100}%`;
  target.style.height = `${(box.height / plan.size.height) * 100}%`;
  target.setAttribute("aria-label", `Node ${nodeId}`);
  target.setAttribute("aria-pressed", String(selection === nodeId));
  return target;
}

function badge(doc: Document, text: string, kind: string): HTMLElement {
  const element = doc.createElement("span");
  element.className = `sb-badge sb-badge-${kind}`;
  element.textContent = text;
  return element;
}

const stateText: Record<PlaceholderState, string> = {
  pending: "compiling…", absent: "provider absent", error: "error", stale: "stale",
};

function placeholderBody(doc: Document, label: string, state: PlaceholderState, message?: string): HTMLElement {
  const body = doc.createElement("div");
  body.className = "sb-placeholder";
  const name = doc.createElement("strong");
  name.textContent = label;
  const status = doc.createElement("span");
  status.className = "sb-placeholder-state";
  status.textContent = stateText[state];
  body.append(name, status);
  if (message !== undefined) {
    const detail = doc.createElement("span");
    detail.className = "sb-placeholder-message";
    detail.textContent = message;
    body.append(detail);
  }
  return body;
}

let drawingCount = 0;

/**
 * An image made ready to paint (an SVG checked and cleaned, a picture as a data address), kept by
 * its bytes: the same image is painted on its slide, its thumbnail and both presenter windows,
 * again at every step, and readying it is the costly part.
 */
const readyImages = new Map<string, Map<string, unknown>>();
let readyCount = 0;
function readied<T>(mime: string, base16: string, make: () => T): T {
  let byBytes = readyImages.get(mime);
  if (byBytes === undefined) { byBytes = new Map(); readyImages.set(mime, byBytes); }
  if (byBytes.has(base16)) return byBytes.get(base16) as T;
  const made = make();
  // a deck that keeps changing its figures must not keep them all
  if (readyCount >= 300) { readyImages.clear(); readyCount = 0; byBytes = new Map(); readyImages.set(mime, byBytes); }
  byBytes.set(base16, made);
  readyCount += 1;
  return made;
}

/** The outline of an arrow head in a 10 by 10 box, pointing right: how wide it is for its length, where the line ends in it, and whether it is strokes rather than a filled shape. */
export function tipShape(kind: DrawingTip["kind"]): { d: string; wide: number; ref: number; stroked: boolean } {
  switch (kind) {
    case "to": return { d: "M 3 0.5 C 4.5 3 7 4.5 10 5 C 7 5.5 4.5 7 3 9.5", wide: 1.1, ref: 9.6, stroked: true };
    case "latex": return { d: "M 0 0.8 C 3 3.4 7 4.6 10 5 C 7 5.4 3 6.6 0 9.2 Z", wide: 0.75, ref: 9, stroked: false };
    case "stealth": return { d: "M 0 0.5 L 10 5 L 0 9.5 L 3.2 5 Z", wide: 0.8, ref: 9, stroked: false };
    case "triangle": return { d: "M 0 0.5 L 10 5 L 0 9.5 Z", wide: 0.9, ref: 9, stroked: false };
    case "bar": return { d: "M 9.5 0 L 9.5 10", wide: 1.4, ref: 9.5, stroked: true };
    case "circle": return { d: "M 0 5 A 5 5 0 1 1 10 5 A 5 5 0 1 1 0 5 Z", wide: 1, ref: 10, stroked: false };
    case "diamond": return { d: "M 0 5 L 5 0.5 L 10 5 L 5 9.5 Z", wide: 0.7, ref: 10, stroked: false };
    case "square": return { d: "M 0 0.5 L 10 0.5 L 10 9.5 L 0 9.5 Z", wide: 1, ref: 10, stroked: false };
  }
}

function makeContentPainter(ctx: PaintContext, figures: Map<string, Extract<Item, { kind: "figure" }>>, pending: Promise<void>[], artifacts: Readonly<Record<string, Artifact>> = {}) {
  const { doc } = ctx;
  const inlineContainers: Record<string, string> = { strong: "strong", em: "em", code: "code", cite: "cite", footnote: "span" };
  const blockContainers: Record<string, string> = {
    u: "u", s: "s", mark: "mark",
    p: "p", h1: "h1", h2: "h2", h3: "h3", h4: "h4", h5: "h5", h6: "h6", quote: "blockquote", ul: "ul", ol: "ol", li: "li",
  };

  function children(nodes: readonly Content[], parent: Node): void {
    for (const node of nodes) parent.appendChild(one(node));
  }

  function one(node: Content): Node {
    switch (node.t) {
      case "text": {
        const text = doc.createTextNode(node.text);
        if (!node.bold && !node.italic && !node.mono && !node.color && node.path === undefined) return text;
        const span = doc.createElement(node.mono ? "code" : "span");
        if (node.path !== undefined) span.setAttribute("data-run-path", node.path.join("."));
        if (node.bold) span.style.fontWeight = "700";
        if (node.italic) span.style.fontStyle = "italic";
        if (node.color) span.style.color = node.color;
        span.append(text);
        return span;
      }
      case "br": return doc.createElement("br");
      case "math": return math(node.tex, node.display);
      case "codeblock": return codeblock(node);
      case "link": {
        const safe = /^(?:https?:|mailto:|#)/i.test(node.href);
        const anchor = doc.createElement(safe ? "a" : "span");
        if (safe) {
          anchor.setAttribute("href", node.href);
          anchor.setAttribute("rel", "noreferrer noopener");
          anchor.setAttribute("target", "_blank");
        }
        children(node.children, anchor);
        return anchor;
      }
      case "table": return table(node);
      case "box": {
        const box = doc.createElement("div");
        box.className = "sb-box";
        box.style.setProperty("--sb-box-fill", node.fill);
        box.style.setProperty("--sb-box-title", node.titleFill);
        if (node.title !== null) {
          const title = doc.createElement("div");
          title.className = "sb-box-title";
          children(node.title, title);
          box.append(title);
        }
        const inner = doc.createElement("div");
        inner.className = "sb-box-body";
        children(node.children, inner);
        box.append(inner);
        return box;
      }
      case "columns": {
        const columns = doc.createElement("div");
        columns.className = "sb-columns";
        for (const column of node.columns) {
          const cell = doc.createElement("div");
          cell.className = "sb-column";
          cell.style.flex = `0 0 ${column.width}`;
          cell.style.width = column.width;
          children(column.children, cell);
          columns.append(cell);
        }
        return columns;
      }
      case "drawing": {
        const wrapper = doc.createElement("span");
        wrapper.className = "sb-inline-figure sb-drawing";
        wrapper.dataset.figure = node.ref;
        wrapper.dataset.scale = String(node.scale);
        wrapper.dataset.planWidth = String(node.width);
        wrapper.dataset.originX = String(node.origin.x);
        wrapper.dataset.originY = String(node.origin.y);
        wrapper.style.width = `calc(var(--sb-unit) * ${node.width})`;
        wrapper.style.height = `calc(var(--sb-unit) * ${node.height})`;
        const svg = doc.createElementNS(svgNamespace, "svg");
        svg.setAttribute("viewBox", `0 0 ${node.width} ${node.height}`);
        svg.setAttribute("class", "sb-drawing-paths");
        const defs = doc.createElementNS(svgNamespace, "defs");
        svg.append(defs);
        const tips = new Map<string, string>();
        // each head is drawn pointing right in a 10 by 10 box, its point at x = 10
        const tip = (found: DrawingTip, color: string, width: number): string => {
          const key = `${found.kind}/${found.length}/${found.open}/${color}/${width}`;
          let id = tips.get(key);
          if (id === undefined) {
            id = `sb-tip-${(drawingCount += 1)}`;
            tips.set(key, id);
            const m = doc.createElementNS(svgNamespace, "marker");
            const shape = tipShape(found.kind);
            const long = Math.max(1, found.length);
            m.setAttribute("id", id);
            m.setAttribute("viewBox", "0 0 10 10");
            m.setAttribute("markerWidth", String(long));
            m.setAttribute("markerHeight", String(long * shape.wide));
            m.setAttribute("preserveAspectRatio", "none");
            m.setAttribute("refX", String(shape.ref));
            m.setAttribute("refY", "5");
            m.setAttribute("orient", "auto-start-reverse");
            m.setAttribute("markerUnits", "userSpaceOnUse");
            m.setAttribute("overflow", "visible");
            const head = doc.createElementNS(svgNamespace, "path");
            head.setAttribute("d", shape.d);
            if (shape.stroked || found.open) {
              head.setAttribute("fill", shape.stroked ? "none" : "#ffffff");
              head.setAttribute("stroke", color);
              head.setAttribute("stroke-width", String((width * 10) / long));
              head.setAttribute("stroke-linecap", "round");
              head.setAttribute("stroke-linejoin", "round");
            } else head.setAttribute("fill", color);
            m.append(head);
            defs.append(m);
          }
          return id;
        };
        wrapper.append(svg);
        for (const item of node.items) {
          if (item.k === "path") {
            const path = doc.createElementNS(svgNamespace, "path");
            path.setAttribute("class", "sb-drawing-path");
            path.setAttribute("data-drawing-id", item.id);
            path.setAttribute("data-drawing-at", String(item.at));
            if (item.of !== undefined) path.setAttribute("data-drawing-node", "1");
            path.setAttribute("d", item.d);
            path.setAttribute("fill", item.fill ?? "none");
            path.setAttribute("stroke", item.stroke?.color ?? "none");
            path.setAttribute("stroke-linejoin", "round");
            if (item.stroke) {
              path.setAttribute("stroke-width", String(item.stroke.width));
              if (item.stroke.dash.length > 0) path.setAttribute("stroke-dasharray", item.stroke.dash.join(" "));
              if (item.tips.end !== null) path.setAttribute("marker-end", `url(#${tip(item.tips.end, item.stroke.color, item.stroke.width)})`);
              if (item.tips.start !== null) path.setAttribute("marker-start", `url(#${tip(item.tips.start, item.stroke.color, item.stroke.width)})`);
            }
            if (item.opacity !== 1) path.setAttribute("opacity", String(item.opacity));
            if (item.rotate && item.about) path.setAttribute("transform", `rotate(${-item.rotate} ${item.about.x} ${item.about.y})`);
            if (item.shadow) path.style.filter = `drop-shadow(${item.shadow.dx}px ${item.shadow.dy}px ${item.shadow.blur}px rgba(0,0,0,${item.shadow.opacity}))`;
            svg.append(path);
          } else {
            const box = doc.createElement("span");
            box.className = "sb-drawing-node";
            box.setAttribute("data-drawing-id", item.id);
            box.setAttribute("data-size-key", item.key);
            box.setAttribute("data-drawing-at", String(item.at));
            box.setAttribute("data-drawing-node", "1");
            box.dataset.source = item.source;
            box.style.left = `${(item.box.x / node.width) * 100}%`;
            box.style.top = `${(item.box.y / node.height) * 100}%`;
            box.style.width = `${(item.box.width / node.width) * 100}%`;
            box.style.height = `${(item.box.height / node.height) * 100}%`;
            box.style.fontSize = `calc(var(--sb-unit) * ${item.size})`;
            box.style.color = item.color;
            if (item.bold) box.style.fontWeight = "700";
            if (item.italic) box.style.fontStyle = "italic";
            if (item.mono) box.style.fontFamily = "ui-monospace, monospace";
            box.style.textAlign = item.align === "left" || item.align === "right" ? item.align : "center";
            if (item.wrap) box.style.whiteSpace = "normal";
            if (item.rotate !== 0) box.style.transform = `rotate(${-item.rotate}deg)`;
            if (item.opacity !== 1) box.style.opacity = String(item.opacity);
            const inner = doc.createElement("span");
            inner.className = "sb-drawing-text";
            children(item.content, inner);
            box.append(inner);
            wrapper.append(box);
          }
        }
        return wrapper;
      }
      case "figure": {
        const wrapper = doc.createElement("span");
        wrapper.className = "sb-inline-figure";
        wrapper.style.width = `calc(var(--sb-unit) * ${node.width})`;
        wrapper.style.height = `calc(var(--sb-unit) * ${node.height})`;
        const item = figures.get(node.fingerprint);
        const ready = artifacts[node.fingerprint] ?? item?.artifact;
        wrapper.append(ready === undefined
          ? placeholderBody(doc, "figure", "pending")
          : artifact(ready.mime, ready.bytesBase16, item?.id ?? node.fingerprint));
        return wrapper;
      }
      case "image": {
        if (node.mime !== undefined && node.bytesBase16 !== undefined && node.width !== undefined && node.height !== undefined) {
          const wrapper = doc.createElement("span");
          wrapper.className = "sb-inline-figure sb-inline-image";
          wrapper.style.width = `calc(var(--sb-unit) * ${node.width})`;
          wrapper.style.height = `calc(var(--sb-unit) * ${node.height})`;
          wrapper.append(artifact(node.mime, node.bytesBase16, node.src, node.alt));
          return wrapper;
        }
        const url = ctx.resolveAsset?.(node.src) ?? null;
        if (url === null) return placeholderBody(doc, node.src, "absent", "image not available");
        const img = doc.createElement("img");
        img.setAttribute("src", url);
        img.setAttribute("alt", node.alt);
        return img;
      }
      case "colour": {
        const span = doc.createElement("span");
        span.style.color = node.color;
        children(node.children, span);
        return span;
      }
      case "div": {
        const div = doc.createElement("div");
        if (node.class !== undefined) div.className = `sb-div ${node.class.replace(/[^A-Za-z0-9_ -]/g, "")}`;
        children(node.children, div);
        return div;
      }
      case "placeholder": {
        const holder = doc.createElement("span");
        holder.className = `sb-inline-placeholder sb-state-${node.state}`;
        if (node.fingerprint !== undefined) holder.dataset.fingerprint = node.fingerprint;
        holder.append(placeholderBody(doc, node.label, node.state));
        return holder;
      }
      case "unsupported": {
        const holder = doc.createElement("span");
        holder.className = "sb-unsupported";
        holder.title = "Retained exactly in the source; the preview cannot render it";
        holder.textContent = `\u26a0 ${node.label}`;
        return holder;
      }
      case "vspace": {
        // \medskip, \bigskip, \vspace{len}: vertical space in em of the body font.
        const gap = doc.createElement("div");
        gap.className = "sb-vspace";
        gap.style.height = `${node.em}em`;
        gap.setAttribute("aria-hidden", "true");
        return gap;
      }
      case "route": {
        // A route choice: a large button. The windows turn a click or a digit key into a route selection.
        const button = doc.createElement("a");
        button.className = "sb-route";
        button.setAttribute("role", "button");
        button.setAttribute("tabindex", "0");
        button.setAttribute("data-route", node.route);
        children(node.children, button);
        return button;
      }
      case "reserved": {
        const wrapper = doc.createElement("span");
        wrapper.className = "sb-reserved";
        wrapper.style.display = "contents";
        wrapper.style.visibility = "hidden";
        wrapper.setAttribute("aria-hidden", "true");
        children(node.children, wrapper);
        return wrapper;
      }
      default: {
        const blockTag = blockContainers[node.t];
        const element = doc.createElement(blockTag ?? inlineContainers[node.t] ?? "span");
        if (node.t === "cite") element.className = "sb-cite";
        if (node.t === "footnote") element.className = "sb-footnote";
        children(node.children, element);
        return element;
      }
    }
  }

  function math(tex: string, display: boolean): HTMLElement {
    const element = doc.createElement(display ? "div" : "span");
    element.className = display ? "sb-math sb-math-display" : "sb-math";
    element.dataset.tex = tex;
    if (ctx.math === undefined || ctx.math === null) {
      element.classList.add("sb-math-absent");
      element.append(placeholderBody(doc, `math: ${tex}`, "absent", "math provider unavailable"));
    } else {
      element.innerHTML = ctx.math.render(tex, display);
    }
    return element;
  }

  function codeblock(node: Extract<Content, { t: "codeblock" }>): HTMLElement {
    const pre = doc.createElement("pre");
    pre.className = "sb-code";
    if (node.language !== null) pre.dataset.language = node.language;
    const marked = new Set(node.highlight ?? []);
    if (marked.size > 0) pre.dataset.emphasis = "true";
    const code = doc.createElement("code");
    const lineElements = node.lines.map((text, index) => {
      const line = doc.createElement("span");
      line.className = "sb-code-line";
      line.dataset.line = String(index + 1);
      line.dataset.hl = marked.has(index + 1) ? "1" : "0";
      line.textContent = text;
      code.append(line, doc.createTextNode("\n"));
      return line;
    });
    pre.append(code);
    const highlighter = ctx.highlighter;
    if (highlighter !== undefined && highlighter !== null && node.language !== null) {
      pending.push(highlighter.highlight(node.lines.join("\n"), node.language).then((tokens) => {
        if (tokens === null) return;
        pre.dataset.highlighted = "true";
        tokens.forEach((lineTokens, index) => {
          const line = lineElements[index];
          if (line !== undefined) paintTokens(doc, line, lineTokens);
        });
      }).catch(() => undefined));
    }
    return pre;
  }

  function table(node: Extract<Content, { t: "table" }>): HTMLElement {
    const element = doc.createElement("table");
    const section = (tag: "thead" | "tbody", rows: readonly (readonly import("../protocol/plan.ts").Cell[])[], cellTag: "th" | "td") => {
      if (rows.length === 0) return;
      const group = doc.createElement(tag);
      for (const row of rows) {
        const tr = doc.createElement("tr");
        for (const cell of row) {
          const td = doc.createElement(cellTag);
          td.style.textAlign = cell.align === "l" ? "left" : cell.align === "r" ? "right" : "center";
          if (cell.colspan !== undefined && cell.colspan > 1) td.setAttribute("colspan", String(cell.colspan));
          if (cell.rowspan !== undefined && cell.rowspan > 1) td.setAttribute("rowspan", String(cell.rowspan));
          children(cell.children, td);
          tr.append(td);
        }
        group.append(tr);
      }
      element.append(group);
    };
    section("thead", node.head, "th");
    section("tbody", node.body, "td");
    return element;
  }

  function artifact(mime: string, base16: string, id: string, alt = ""): HTMLElement {
    const holder = doc.createElement("div");
    holder.className = "sb-artifact";
    holder.dataset.itemId = id;
    if (mime === "image/svg+xml") {
      const clean = readied(mime, base16, () => sanitizeSvg(new TextDecoder().decode(bytesFromBase16(base16))));
      if (clean === null) {
        holder.append(placeholderBody(doc, id, "error", "the figure is not valid SVG"));
      } else {
        holder.innerHTML = clean.svg;
        holder.dataset.intrinsicWidth = String(clean.width ?? "");
        holder.dataset.intrinsicHeight = String(clean.height ?? "");
      }
    } else if (/^image\/(?:png|jpeg|gif|webp)$/.test(mime)) {
      const img = doc.createElement("img");
      img.setAttribute("src", readied(mime, base16, () => `data:${mime};base64,${toBase64(bytesFromBase16(base16))}`));
      img.setAttribute("alt", alt);
      holder.append(img);
    } else {
      holder.append(placeholderBody(doc, id, "error", `unsupported artifact type ${mime}`));
    }
    return holder;
  }

  return { children, artifact };
}

function paintTokens(doc: Document, line: HTMLElement, tokens: readonly HighlightToken[]): void {
  line.textContent = "";
  for (const token of tokens) {
    const span = doc.createElement("span");
    span.textContent = token.text;
    if (token.color !== undefined) span.style.color = token.color;
    if (token.fontStyle !== undefined) {
      if (token.fontStyle & 1) span.style.fontStyle = "italic";
      if (token.fontStyle & 2) span.style.fontWeight = "700";
      if (token.fontStyle & 4) span.style.textDecoration = "underline";
    }
    line.append(span);
  }
}

function toBase64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

/** Paint a content tree into `parent` (used by the measurer and the presenter console). */
export function paintContentInto(parent: HTMLElement, nodes: readonly Content[], ctx: PaintContext): Promise<void> {
  const pending: Promise<void>[] = [];
  makeContentPainter(ctx, new Map(), pending).children(nodes, parent);
  return Promise.all(pending).then(() => undefined);
}
