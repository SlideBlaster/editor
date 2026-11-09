/**
 * Allowlist SVG sanitizer for provider artifacts (design 4.3 step 4: no script, no
 * external refs). Works on strings so it runs identically in the browser and in Node tests:
 * a quote-aware tag scanner rebuilds the document from allowed elements and attributes only.
 */

const allowedElements = new Set([
  "svg", "g", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon", "text", "tspan",
  "defs", "marker", "clippath", "mask", "lineargradient", "radialgradient", "stop", "pattern",
  "symbol", "use", "title", "desc", "image", "switch",
]);
/** Elements dropped together with their whole content. */
const droppedWithContent = new Set(["script", "foreignobject", "style", "iframe", "object", "embed", "animate", "animatetransform", "animatemotion", "set", "metadata"]);
const urlAttributes = new Set(["href", "xlink:href"]);

export interface SanitizedSvg {
  readonly svg: string;
  readonly width: number | null;
  readonly height: number | null;
}

export function sanitizeSvg(input: string): SanitizedSvg | null {
  const out: string[] = [];
  const stack: string[] = [];
  let skipDepth = 0;
  let skipName = "";
  let rootSeen = false;
  let width: number | null = null;
  let height: number | null = null;
  let i = 0;
  const n = input.length;
  while (i < n) {
    if (input[i] !== "<") {
      const next = input.indexOf("<", i);
      const end = next < 0 ? n : next;
      if (skipDepth === 0 && rootSeen) out.push(escapeText(input.slice(i, end)));
      i = end;
      continue;
    }
    if (input.startsWith("<!--", i)) { const e = input.indexOf("-->", i + 4); i = e < 0 ? n : e + 3; continue; }
    if (input.startsWith("<![CDATA[", i)) { const e = input.indexOf("]]>", i + 9); if (skipDepth === 0 && rootSeen && e >= 0) out.push(escapeText(input.slice(i + 9, e))); i = e < 0 ? n : e + 3; continue; }
    if (input.startsWith("<?", i) || input.startsWith("<!", i)) { const e = input.indexOf(">", i + 2); i = e < 0 ? n : e + 1; continue; }
    const tag = readTag(input, i);
    if (tag === null) return null;
    i = tag.end;
    const name = tag.name.toLowerCase();
    const local = name.includes(":") ? name.slice(name.indexOf(":") + 1) : name;
    if (tag.closing) {
      if (skipDepth > 0) {
        if (local === skipName) skipDepth -= 1;
        continue;
      }
      const top = stack[stack.length - 1];
      if (top === `~${local}`) stack.pop();
      else if (top === local) { stack.pop(); out.push(`</${tag.name}>`); }
      continue;
    }
    if (skipDepth > 0) {
      if (local === skipName && !tag.selfClosing) skipDepth += 1;
      continue;
    }
    if (droppedWithContent.has(local)) {
      if (!tag.selfClosing) { skipDepth = 1; skipName = local; }
      continue;
    }
    if (!rootSeen) {
      if (local !== "svg") return null;
      rootSeen = true;
    }
    if (!allowedElements.has(local)) {
      // Unknown element: drop the tag but keep walking its (sanitised) children.
      if (!tag.selfClosing) stack.push(`~${local}`);
      continue;
    }
    const attrs = tag.attributes.filter(([key, value]) => keepAttribute(key.toLowerCase(), value));
    if (local === "svg" && stack.length === 0) {
      width = lengthOf(attrs, "width");
      height = lengthOf(attrs, "height");
      const viewBox = attrs.find(([k]) => k.toLowerCase() === "viewbox");
      const rest = attrs.filter(([k]) => !["width", "height", "style", "viewbox", "preserveaspectratio", "x", "y"].includes(k.toLowerCase()));
      const box = viewBox?.[1] ?? (width !== null && height !== null ? `0 0 ${width} ${height}` : null);
      if (box !== null) rest.push(["viewBox", box]);
      rest.push(["preserveAspectRatio", "xMidYMid meet"]);
      attrs.length = 0;
      attrs.push(...rest);
    }
    out.push(`<${tag.name}${attrs.map(([k, v]) => ` ${k}="${escapeAttr(v)}"`).join("")}${tag.selfClosing ? "/" : ""}>`);
    if (!tag.selfClosing) stack.push(local);
  }
  if (!rootSeen) return null;
  while (stack.length > 0) { const open = stack.pop()!; if (!open.startsWith("~")) out.push(`</${open}>`); }
  return { svg: out.join(""), width, height };
}

interface Tag {
  readonly name: string;
  readonly closing: boolean;
  readonly selfClosing: boolean;
  readonly attributes: [string, string][];
  readonly end: number;
}

function readTag(input: string, start: number): Tag | null {
  let i = start + 1;
  const closing = input[i] === "/";
  if (closing) i += 1;
  const nameStart = i;
  while (i < input.length && /[A-Za-z0-9:_-]/.test(input[i]!)) i += 1;
  const name = input.slice(nameStart, i);
  if (name === "") return null;
  const attributes: [string, string][] = [];
  let selfClosing = false;
  while (i < input.length) {
    while (i < input.length && /\s/.test(input[i]!)) i += 1;
    if (input[i] === ">") return { name, closing, selfClosing, attributes, end: i + 1 };
    if (input[i] === "/") { selfClosing = true; i += 1; continue; }
    const keyStart = i;
    while (i < input.length && !/[\s=/>]/.test(input[i]!)) i += 1;
    const key = input.slice(keyStart, i);
    if (key === "") return null;
    while (i < input.length && /\s/.test(input[i]!)) i += 1;
    let value = "";
    if (input[i] === "=") {
      i += 1;
      while (i < input.length && /\s/.test(input[i]!)) i += 1;
      const quote = input[i];
      if (quote === "\"" || quote === "'") {
        const e = input.indexOf(quote, i + 1);
        if (e < 0) return null;
        value = input.slice(i + 1, e);
        i = e + 1;
      } else {
        const valueStart = i;
        while (i < input.length && !/[\s>]/.test(input[i]!)) i += 1;
        value = input.slice(valueStart, i);
      }
    }
    if (!closing) attributes.push([key, decodeEntities(value)]);
  }
  return null;
}

function keepAttribute(key: string, value: string): boolean {
  if (key.startsWith("on")) return false;
  if (key === "style") return !/url\(\s*(?!#)|expression\(|@import|javascript:/i.test(value);
  if (urlAttributes.has(key)) return value.startsWith("#") || /^data:image\/(?:png|jpeg|gif|svg\+xml|webp);/i.test(value);
  if (/^(?:xmlns:(?!xlink)|xml:base|requiredextensions|externalresourcesrequired)/.test(key)) return false;
  return !/javascript:/i.test(value) && !/url\(\s*(?!#|['"]?#)/i.test(value);
}

function lengthOf(attrs: [string, string][], name: string): number | null {
  const found = attrs.find(([k]) => k.toLowerCase() === name)?.[1];
  if (found === undefined) return null;
  const match = /^\s*([0-9]*\.?[0-9]+)\s*(px|pt|)\s*$/.exec(found);
  if (match === null) return null;
  const value = Number(match[1]);
  return match[2] === "pt" ? value * (96 / 72) : value;
}

function decodeEntities(text: string): string {
  return text.replace(/&(lt|gt|amp|quot|apos|#[0-9]+|#x[0-9a-fA-F]+);/g, (_m, e: string) => {
    if (e === "lt") return "<";
    if (e === "gt") return ">";
    if (e === "amp") return "&";
    if (e === "quot") return "\"";
    if (e === "apos") return "'";
    const code = e[1] === "x" ? Number.parseInt(e.slice(2), 16) : Number.parseInt(e.slice(1), 10);
    return Number.isFinite(code) && code > 0 && code < 0x110000 ? String.fromCodePoint(code) : "";
  });
}
const escapeText = (text: string): string => text.replace(/&(?!(?:lt|gt|amp|quot|apos|#[0-9]+|#x[0-9a-fA-F]+);)/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const escapeAttr = (text: string): string => text.replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
