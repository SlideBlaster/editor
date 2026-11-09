/**
 * Out-of-bounds check for a painted slide: content that the browser lays out past its item box
 * (text running onto the footer, a code line wider than the column) or past the slide edge.
 * The core lays items out from measurements; this catches the cases where the real fonts and
 * theme CSS disagree with them. DOM only, read-only.
 */

export interface Overflow {
  readonly frame: string;
  readonly step: number;
  readonly steps: number;
  /** First words of the item's text, to find it in the deck. */
  readonly item: string;
  /** How far the content runs off each side of the slide, in percent of its height/width. */
  readonly bottom: number;
  readonly right: number;
  readonly top: number;
  readonly left: number;
  /** Other items its content lands on (their first words). */
  readonly overlaps: readonly string[];
}

/** Slack below which a spill or overlap is rounding, not overflow (fraction of the slide size). */
const tolerance = 0.003;

type Box = { readonly top: number; readonly bottom: number; readonly left: number; readonly right: number };

/**
 * Where an item's content really is: one rect per line of visible text, plus images, SVG and
 * canvases. Hidden helpers (KaTeX's MathML copy, `visibility: hidden` reserved space) do not count.
 */
function contentRects(item: HTMLElement): Box[] {
  const doc = item.ownerDocument;
  const view = doc.defaultView;
  const out: Box[] = [];
  const visible = (el: Element): boolean => {
    if (el.closest(".katex-mathml") !== null) return false;
    const style = view?.getComputedStyle(el);
    return style === undefined || (style.visibility !== "hidden" && style.display !== "none" && style.opacity !== "0");
  };
  const walker = doc.createTreeWalker(item, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT);
  for (let node = walker.nextNode(); node !== null; node = walker.nextNode()) {
    if (node.nodeType === Node.TEXT_NODE) {
      const parent = node.parentElement;
      if (parent === null || (node.textContent ?? "").trim() === "" || !visible(parent)) continue;
      const range = doc.createRange();
      range.selectNodeContents(node);
      for (const r of range.getClientRects()) if (r.width > 0 && r.height > 0) out.push(r);
    } else {
      const el = node as Element;
      if (!["IMG", "svg", "CANVAS", "OBJECT"].includes(el.tagName) || !visible(el)) continue;
      const r = el.getBoundingClientRect();
      if (r.width > 0 && r.height > 0) out.push(r);
    }
  }
  return out;
}

function union(rects: readonly Box[]): Box {
  return {
    top: Math.min(...rects.map((r) => r.top)), bottom: Math.max(...rects.map((r) => r.bottom)),
    left: Math.min(...rects.map((r) => r.left)), right: Math.max(...rects.map((r) => r.right)),
  };
}

/** Overlap area of two boxes, as a fraction of the smaller one. */
function overlap(a: Box, b: Box): number {
  const w = Math.min(a.right, b.right) - Math.max(a.left, b.left);
  const h = Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top);
  if (w <= 0 || h <= 0) return 0;
  const area = (r: Box): number => (r.right - r.left) * (r.bottom - r.top);
  return (w * h) / Math.max(1, Math.min(area(a), area(b)));
}

/**
 * Content that runs off a painted `.sb-slide`, lands on another item (the footer logo, the page
 * number, the title), or is clipped (a code line wider than its block). Needs the slide laid out.
 */
export function findOverflows(slide: HTMLElement): readonly Overflow[] {
  const frame = slide.dataset.frame ?? "";
  const step = Number(slide.dataset.step ?? "1");
  const steps = Number(slide.dataset.steps ?? "1");
  const bounds = slide.getBoundingClientRect();
  if (bounds.width <= 0 || bounds.height <= 0) return [];
  const items = [...slide.querySelectorAll<HTMLElement>(".sb-layer-content > .sb-item")]
    .map((el) => ({ el, name: snippet(el.textContent ?? "") || "(figure)", rects: contentRects(el) }))
    .filter((i) => i.rects.length > 0);
  const found: Overflow[] = [];
  for (const [index, item] of items.entries()) {
    if (!item.el.matches(".sb-text, .sb-flow")) continue;
    const content = union(item.rects);
    const off = (v: number, size: number): number => (v / size > tolerance ? Math.round((v / size) * 1000) / 10 : 0);
    let right = off(content.right - bounds.right, bounds.width);
    // A code block clips its own long lines, so they never show up as rects past the slide.
    for (const pre of item.el.querySelectorAll<HTMLElement>(".sb-code")) {
      if (pre.scrollWidth > pre.clientWidth + 1) right = Math.max(right, off(pre.scrollWidth - pre.clientWidth, bounds.width));
    }
    const overlaps = items
      .filter((other, j) => j !== index && !(other.el.matches(".sb-text, .sb-flow") && j < index))
      .filter((other) => item.rects.some((a) => other.rects.some((b) => overlap(a, b) > 0.05)))
      .map((other) => other.name);
    const result = {
      frame, step, steps, item: item.name, overlaps,
      bottom: off(content.bottom - bounds.bottom, bounds.height), top: off(bounds.top - content.top, bounds.height),
      right, left: off(bounds.left - content.left, bounds.width),
    };
    if (overlaps.length > 0 || result.bottom + result.top + result.right + result.left > 0) found.push(result);
  }
  return found;
}

function snippet(text: string): string {
  const flat = text.replace(/\s+/g, " ").trim();
  return flat.length > 40 ? `${flat.slice(0, 40)}…` : flat;
}

/** One line per overflow, e.g. `yaaihh-call step 2/2: "Typed: …" runs 3.1% off the bottom`. */
export function describeOverflow(o: Overflow): string {
  const sides = (["bottom", "right", "top", "left"] as const).filter((s) => o[s] > 0).map((s) => `runs ${o[s]}% off the ${s}`);
  const lands = o.overlaps.map((name) => `lands on "${name}"`);
  return `${o.frame}${o.steps > 1 ? ` step ${o.step}/${o.steps}` : ""}: "${o.item}" ${[...sides, ...lands].join(", ")}`;
}
