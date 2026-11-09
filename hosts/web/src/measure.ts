/**
 * DOM text measurer: the host's answer to the core's `measure` effect (session/1 section 3),
 * ported from editor/packages/app/src/domMeasurer.ts. The effect asks for the box that
 * `content` occupies when laid out at `width` slide pixels; the host paints the same
 * closed content tree into an offscreen slide (so fonts, KaTeX and tables are exactly as
 * painted), reads the box, and answers with one `measurement_result`. Results are cached
 * by (content hash, width, font key) so a keystroke only measures what changed.
 */
import type { Content } from "./protocol/plan.ts";
import { paintContentInto, type PaintContext } from "./plan/paint.ts";

export interface MeasureItem {
  readonly key: string;
  readonly content: unknown;
  readonly width: number;
}

export interface MeasureResult {
  readonly key: string;
  readonly width: number;
  readonly height: number;
}

export interface DomMeasurerOptions {
  readonly doc: Document;
  readonly paint: Omit<PaintContext, "doc">;
  /** Slide design width in px; the offscreen slide is exactly this wide so 1 unit = 1 px. */
  readonly designWidth?: number;
  /** Font stack applied to measured content (the theme body font). */
  readonly fontFamily?: string;
  /** Test seam: read a laid-out element's size. Defaults to `getBoundingClientRect`. */
  readonly readBox?: (element: HTMLElement) => { width: number; height: number };
  readonly fontsReady?: () => Promise<unknown>;
}

export interface DomMeasurer {
  measureAll(items: readonly MeasureItem[]): Promise<MeasureResult[]>;
  /** Forget cached boxes (fonts or theme changed). */
  reset(): void;
  readonly stats: { readonly reads: number; readonly hits: number };
  dispose(): void;
}

export function createDomMeasurer(options: DomMeasurerOptions): DomMeasurer {
  const { doc } = options;
  const designWidth = options.designWidth ?? 1280;
  const readBox = options.readBox ?? ((el: HTMLElement) => el.getBoundingClientRect());
  const root = doc.createElement("div");
  root.className = "sb-measure-root";
  root.setAttribute("aria-hidden", "true");
  root.style.cssText = "position:fixed;left:-100000px;top:0;visibility:hidden;pointer-events:none";
  const slide = doc.createElement("div");
  slide.className = "sb-slide sb-measure-slide";
  slide.style.width = `${designWidth}px`;
  slide.style.setProperty("--sb-unit", `calc(100cqw / ${designWidth})`);
  slide.style.height = "auto";
  slide.style.overflow = "visible";
  root.append(slide);
  doc.body.append(root);

  const cache = new Map<string, { width: number; height: number }>();
  const stats = { reads: 0, hits: 0 };
  let ready: Promise<unknown> | null = null;

  const cacheKey = (item: MeasureItem): string =>
    `${hash(JSON.stringify(item.content))}|${item.width}|${options.fontFamily ?? ""}`;

  return {
    async measureAll(items) {
      ready ??= (options.fontsReady?.() ?? (doc as Document & { fonts?: { ready: Promise<unknown> } }).fonts?.ready ?? Promise.resolve());
      await ready;
      const misses = new Map<string, MeasureItem>();
      for (const item of items) {
        const key = cacheKey(item);
        if (cache.has(key)) stats.hits += 1;
        else misses.set(key, item);
      }
      if (misses.size > 0) {
        const elements = new Map<string, HTMLElement>();
        slide.replaceChildren();
        const painting: Promise<void>[] = [];
        for (const [key, item] of misses) {
          const el = doc.createElement("div");
          el.style.width = `${item.width}px`;
          if (options.fontFamily !== undefined) el.style.fontFamily = options.fontFamily;
          painting.push(paintContentInto(el, item.content as readonly Content[], { ...options.paint, doc }));
          slide.append(el);
          elements.set(key, el);
        }
        await Promise.all(painting);
        for (const [key, el] of elements) {
          const box = readBox(el);
          stats.reads += 1;
          cache.set(key, { width: Math.ceil(box.width * 1000) / 1000, height: Math.ceil(box.height * 1000) / 1000 });
        }
        slide.replaceChildren();
      }
      return items.map((item) => ({ key: item.key, ...cache.get(cacheKey(item))! }));
    },
    reset() { cache.clear(); },
    stats,
    dispose() { root.remove(); },
  };
}

/** FNV-1a over UTF-16 code units; a cache key, not a security primitive. */
function hash(text: string): string {
  let h = 0x811c9dc5;
  for (let i = 0; i < text.length; i += 1) {
    h ^= text.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h.toString(16);
}
