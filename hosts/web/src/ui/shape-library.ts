/**
 * The shape library offered when creating an element: the catalog that ships with the editor
 * (`dist/catalog/catalog-v1.json`, draw.io stencils, CC BY 4.0; see `dist/catalog/THIRD_PARTY_NOTICES.md`).
 *
 * A shape is nothing special in a deck: choosing one writes `\node[<id>] ..`, and `<id>` is a
 * named style defined in the library file `shapes/<family>.tikz` (generated from the same catalog
 * by the build) as `outline={<path>}` plus a starting size. A deck can define its own the same way.
 * This module is only the picker's data: search, grouping and a thumbnail.
 */
const svgNamespace = "http://www.w3.org/2000/svg";

export interface Shape {
  /** The style name written on the node, `family.name`. */
  readonly id: string;
  readonly label: string;
  /** `Group / Subgroup` as the catalog names it. */
  readonly category: string;
  readonly keywords: readonly string[];
  /** Outline in a unit box: x right, y down, both from 0 to 1. */
  readonly path: string;
  /** Starting size in slide units. */
  readonly width: number;
  readonly height: number;
}

export interface ShapeLibrary {
  readonly shapes: readonly Shape[];
  /** First-level groups with their shape counts, largest first. */
  readonly groups: readonly { readonly name: string; readonly count: number }[];
  search(query: string, group?: string | null): Shape[];
}

/** Absolute SVG path data restricted to what the catalog uses: M L Q C A Z and plain numbers. */
const outlinePattern = /^\s*M(?:[\s,]*(?:[MLQCAZ]|-?(?:\d+\.?\d*|\.\d+)(?:e-?\d+)?))*\s*$/;
export function isOutline(d: unknown): d is string {
  return typeof d === "string" && d.length <= 200000 && outlinePattern.test(d);
}

const groupOf = (category: string): string => category.split(" / ")[0]!.trim();

export function shapeLibrary(catalog: unknown): ShapeLibrary {
  const rows = (catalog as { shapes?: unknown } | null)?.shapes;
  const shapes: Shape[] = [];
  for (const row of Array.isArray(rows) ? rows : []) {
    const r = row as { id?: unknown; label?: unknown; category?: unknown; keywords?: unknown; path?: unknown; size?: { width?: unknown; height?: unknown } };
    if (typeof r.id !== "string" || !/^[a-z0-9_-]+(\.[A-Za-z0-9_-]+)+$/.test(r.id) || !isOutline(r.path)) continue;
    const width = Number(r.size?.width), height = Number(r.size?.height);
    shapes.push({
      id: r.id, label: typeof r.label === "string" ? r.label : r.id, category: typeof r.category === "string" ? r.category : "Other",
      keywords: Array.isArray(r.keywords) ? r.keywords.filter((k): k is string => typeof k === "string") : [],
      path: r.path, width: width > 0 ? width : 2, height: height > 0 ? height : 2,
    });
  }
  const counts = new Map<string, number>();
  for (const shape of shapes) counts.set(groupOf(shape.category), (counts.get(groupOf(shape.category)) ?? 0) + 1);
  const groups = [...counts].map(([name, count]) => ({ name, count })).sort((a, b) => b.count - a.count || a.name.localeCompare(b.name));
  const haystack = shapes.map((s) => `${s.label}\n${s.keywords.join("\n")}\n${s.category}\n${s.id}`.toLowerCase());
  return {
    shapes, groups,
    /** Shapes matching every typed word, best first: label starts with it, label has it, then keywords and the rest. */
    search(query, group) {
      const words = query.toLowerCase().split(/\s+/).filter((w) => w !== "");
      const scored: { shape: Shape; score: number; index: number }[] = [];
      shapes.forEach((shape, index) => {
        if (group != null && groupOf(shape.category) !== group) return;
        const hay = haystack[index]!;
        if (!words.every((w) => hay.includes(w))) return;
        const label = shape.label.toLowerCase();
        const score = words.length === 0 ? 3 : words.every((w) => label.startsWith(w)) ? 0 : words.every((w) => label.includes(w)) ? 1 : words.every((w) => shape.keywords.some((k) => k.toLowerCase().includes(w))) ? 2 : 3;
        scored.push({ shape, score, index });
      });
      return scored.sort((a, b) => a.score - b.score || a.index - b.index).map((s) => s.shape);
    },
  };
}

/** A small drawing of a shape, keeping its proportions. */
export function shapeThumbnail(doc: Document, shape: Pick<Shape, "path" | "width" | "height">, size = 40): SVGSVGElement {
  const svg = doc.createElementNS(svgNamespace, "svg") as SVGSVGElement;
  const scale = size / Math.max(shape.width, shape.height);
  svg.setAttribute("width", String(size));
  svg.setAttribute("height", String(size));
  svg.setAttribute("viewBox", `0 0 ${size} ${size}`);
  svg.setAttribute("aria-hidden", "true");
  const inner = doc.createElementNS(svgNamespace, "svg");
  const w = Math.max(2, shape.width * scale - 2), h = Math.max(2, shape.height * scale - 2);
  inner.setAttribute("x", String((size - w) / 2));
  inner.setAttribute("y", String((size - h) / 2));
  inner.setAttribute("width", String(w));
  inner.setAttribute("height", String(h));
  inner.setAttribute("viewBox", "0 0 1 1");
  inner.setAttribute("preserveAspectRatio", "none");
  inner.setAttribute("overflow", "visible");
  const path = doc.createElementNS(svgNamespace, "path");
  path.setAttribute("d", shape.path);
  path.setAttribute("fill", "none");
  path.setAttribute("stroke", "currentColor");
  path.setAttribute("stroke-width", "1.2");
  path.setAttribute("vector-effect", "non-scaling-stroke");
  inner.append(path);
  svg.append(inner);
  return svg;
}

/** Fetch the catalog once; later calls share the result. */
export function createShapeLoader(url: string, fetcher: (url: string) => Promise<{ ok: boolean; json(): Promise<unknown> }> = (u) => fetch(u)): () => Promise<ShapeLibrary> {
  let loaded: Promise<ShapeLibrary> | null = null;
  return () => {
    loaded ??= fetcher(url).then(async (response) => {
      if (!response.ok) throw new Error("the shape library is not part of this build");
      return shapeLibrary(await response.json());
    }).catch((failure: unknown) => { loaded = null; throw failure; });
    return loaded;
  };
}
