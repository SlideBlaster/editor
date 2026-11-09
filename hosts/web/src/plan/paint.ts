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
import type { Artifact, Box, Content, Item, Plan, PlaceholderState } from "../protocol/plan.ts";
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

  const geometry = doc.createElementNS(svgNamespace, "svg");
  geometry.setAttribute("class", "sb-layer sb-layer-geometry");
  geometry.setAttribute("viewBox", `0 0 ${width} ${height}`);
  geometry.setAttribute("preserveAspectRatio", "none");
  geometry.setAttribute("aria-hidden", "true");
  const content = doc.createElement("div");
  content.className = "sb-layer sb-layer-content";
  const overlay = doc.createElement("div");
  overlay.className = "sb-layer sb-layer-overlay";

  const figuresByFingerprint = new Map<string, Extract<Item, { kind: "figure" }>>();
  for (const item of plan.items) if (item.kind === "figure") figuresByFingerprint.set(item.fingerprint, item);

  const painter = makeContentPainter(ctx, figuresByFingerprint, pending, plan.artifacts ?? {});
  const defs = doc.createElementNS(svgNamespace, "defs");
  geometry.append(defs);
  const markers = new Map<string, string>();
  const marker = (color: string, end: "start" | "end"): string => {
    const key = `${end}${color}`;
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
      path.setAttribute("d", end === "end" ? "M0,0 L10,5 L0,10 z" : "M10,0 L0,5 L10,10 z");
      path.setAttribute("fill", color);
      m.append(path);
      defs.append(m);
    }
    return id;
  };

  for (const item of plan.items) {
    switch (item.kind) {
      case "rect": {
        const rect = doc.createElementNS(svgNamespace, "rect");
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
        if (item.arrow === "end" || item.arrow === "both") line.setAttribute("marker-end", `url(#${marker(item.stroke.color, "end")})`);
        if (item.arrow === "both") line.setAttribute("marker-start", `url(#${marker(item.stroke.color, "start")})`);
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
  root.append(geometry, content, overlay);
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
    const bytes = bytesFromBase16(base16);
    if (mime === "image/svg+xml") {
      const clean = sanitizeSvg(new TextDecoder().decode(bytes));
      if (clean === null) {
        holder.append(placeholderBody(doc, id, "error", "the figure is not valid SVG"));
      } else {
        holder.innerHTML = clean.svg;
        holder.dataset.intrinsicWidth = String(clean.width ?? "");
        holder.dataset.intrinsicHeight = String(clean.height ?? "");
      }
    } else if (/^image\/(?:png|jpeg|gif|webp)$/.test(mime)) {
      const img = doc.createElement("img");
      img.setAttribute("src", `data:${mime};base64,${toBase64(bytes)}`);
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
