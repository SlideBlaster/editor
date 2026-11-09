/**
 * Continuous vertical deck preview plus the thumbnail rail (design 5, F13/F14).
 *
 * Every navigator item is painted from the plan the core projected for it; only the active
 * slide, painted from `view.active.plan`, gets interaction targets. The rail highlights the
 * slide under the reading line as the preview scrolls and scrolls the preview on click.
 * Nothing here decides what is active: selection is a request to the core.
 */
import type { Plan } from "../protocol/plan.ts";
import type { NavigatorItem, View } from "../protocol/session.ts";
import { paintPlan, type PaintContext } from "../plan/paint.ts";
import { attachPointerFacts, type PointerSink } from "./pointer-facts.ts";

export interface DeckViewOptions {
  readonly doc: Document;
  /** The scrolling element that holds the continuous preview. */
  readonly scroller: HTMLElement;
  readonly canvas: HTMLElement;
  readonly rail: HTMLElement;
  readonly paint: Omit<PaintContext, "doc" | "interactive" | "selection">;
  readonly sink: PointerSink;
  readonly onSelect: (frame: string) => void;
  /** A slide is shown with its notes aside in the preview. */
  readonly showNotes?: boolean;
  /** The reading line moved to another slide as the user scrolled. */
  readonly onVisibleFrame?: (frame: string) => void;
  readonly onNodeClick?: (frame: string, nodeId: string) => void;
  /** Present in the desktop shell: switch to the deck an included slide comes from (its deck file, relative to this deck's folder). */
  readonly onOpenOrigin?: (path: string) => void;
}

export interface DeckView {
  update(view: View, selection?: string | null): Promise<void>;
  scrollToFrame(frame: string, behavior?: ScrollBehavior): void;
  setShowNotes(show: boolean): void;
  visibleFrame(): string | null;
  /** Re-measure which slide is under the reading line (called on scroll). */
  syncRail(): void;
  destroy(): void;
}

export interface RowGeometry { readonly frame: string; readonly top: number; readonly bottom: number }

/** The row holding the reading line (35% down the viewport), else the nearest row. */
export function frameAtReadingLine(rows: readonly RowGeometry[], viewport: { top: number; height: number }): string | null {
  if (rows.length === 0) return null;
  const line = viewport.top + viewport.height * 0.35;
  let best = rows[0]!;
  let bestDistance = Number.POSITIVE_INFINITY;
  for (const row of rows) {
    const distance = line < row.top ? row.top - line : line > row.bottom ? line - row.bottom : 0;
    if (distance < bestDistance) { best = row; bestDistance = distance; }
  }
  return best.frame;
}

export function createDeckView(options: DeckViewOptions): DeckView {
  const { doc, scroller, canvas, rail } = options;
  const rows = new Map<string, { row: HTMLElement; slide: HTMLElement; notes: HTMLElement; key: string; detach: (() => void) | null }>();
  const thumbs = new Map<string, { button: HTMLElement; card: HTMLElement; key: string }>();
  let current: string | null = null;
  let showNotes = options.showNotes ?? true;
  canvas.dataset.notes = String(showNotes);
  const settled: Promise<void>[] = [];

  const keyOf = (plan: Plan | null, extra = ""): string => plan === null ? "none" : `${plan.revision}:${plan.ticket}:${plan.step}${extra}`;

  function paintInto(holder: HTMLElement, plan: Plan | null, interactive: boolean, selection: string | null): (() => void) | null {
    holder.replaceChildren();
    if (plan === null) return null;
    const painted = paintPlan(plan, { ...options.paint, doc, interactive, selection });
    holder.append(painted.element);
    settled.push(painted.settled);
    return interactive ? attachPointerFacts(painted.element, plan, options.sink) : null;
  }

  function ensureRow(item: NavigatorItem, index: number) {
    let entry = rows.get(item.frame);
    if (entry === undefined) {
      const row = doc.createElement("article");
      row.className = "deck-row";
      row.dataset.frame = item.frame;
      const slide = doc.createElement("div");
      slide.className = "deck-slide";
      slide.dataset.frame = item.frame;
      const notes = doc.createElement("aside");
      notes.className = "deck-note";
      row.append(slide, notes);
      row.addEventListener("click", (event) => {
        const hit = (event.target as Element).closest?.(".sb-hit") as HTMLElement | null;
        if (hit !== null) options.onNodeClick?.(item.frame, hit.dataset.nodeId ?? "");
        else options.onSelect(item.frame);
      });
      entry = { row, slide, notes, key: "", detach: null };
      rows.set(item.frame, entry);
    }
    entry.row.setAttribute("aria-label", item.title || `Slide ${index + 1}`);
    return entry;
  }

  /** The "from <deck> - open" badge of an included slide; painting clears the slide, so it is re-added. */
  function syncOrigin(slide: HTMLElement, item: NavigatorItem): void {
    const present = slide.querySelector(".deck-origin");
    const origin = item.origin;
    if (!origin) { present?.remove(); return; }
    if (present !== null && present.getAttribute("data-path") === origin.path) return;
    present?.remove();
    const badge = doc.createElement("div");
    badge.className = "deck-origin";
    badge.setAttribute("data-path", origin.path);
    badge.title = `Included from ${origin.path}; read-only here`;
    const label = doc.createElement("span");
    label.textContent = `from ${origin.deck}`;
    badge.append(label);
    if (options.onOpenOrigin !== undefined) {
      const open = doc.createElement("button");
      open.type = "button";
      open.className = "deck-origin-open";
      open.textContent = "open";
      open.addEventListener("click", (event) => { event.stopPropagation(); options.onOpenOrigin?.(origin.path); });
      badge.append(doc.createTextNode(" \u2014 "), open);
    }
    slide.append(badge);
  }

  function ensureThumb(item: NavigatorItem, index: number) {
    let entry = thumbs.get(item.frame);
    if (entry === undefined) {
      const button = doc.createElement("button");
      button.type = "button";
      button.className = "slide-thumb";
      button.dataset.frame = item.frame;
      const number = doc.createElement("span");
      number.className = "slide-thumb-number";
      const card = doc.createElement("span");
      card.className = "thumb-card";
      button.append(number, card);
      button.addEventListener("click", () => { options.onSelect(item.frame); scrollToFrame(item.frame); });
      entry = { button, card, key: "" };
      thumbs.set(item.frame, entry);
    }
    (entry.button.querySelector(".slide-thumb-number") as HTMLElement).textContent = String(index + 1);
    entry.button.setAttribute("aria-label", `Slide ${index + 1}: ${item.title || "Untitled"}`);
    return entry;
  }

  function markCurrent(frame: string | null): void {
    current = frame;
    for (const [name, t] of thumbs) {
      const on = name === frame;
      t.button.classList.toggle("is-current", on);
      if (on) t.button.setAttribute("aria-current", "true"); else t.button.removeAttribute("aria-current");
    }
    for (const [name, r] of rows) r.row.classList.toggle("is-current", name === frame);
  }

  function scrollToFrame(frame: string, behavior: ScrollBehavior = "smooth"): void {
    const entry = rows.get(frame);
    if (entry === undefined) return;
    const top = entry.row.offsetTop - 16;
    scroller.scrollTo({ top: Math.max(0, top), behavior });
  }

  let railFrame: string | null = null;
  function syncRail(): void {
    const box = scroller.getBoundingClientRect();
    const geometry: RowGeometry[] = [...rows].map(([frame, r]) => {
      const rect = r.row.getBoundingClientRect();
      return { frame, top: rect.top - box.top, bottom: rect.bottom - box.top };
    });
    const frame = frameAtReadingLine(geometry, { top: 0, height: box.height });
    if (frame === null || frame === railFrame) return;
    railFrame = frame;
    markCurrent(frame);
    thumbs.get(frame)?.button.scrollIntoView({ block: "nearest" });
    options.onVisibleFrame?.(frame);
  }
  const onScroll = () => syncRail();
  scroller.addEventListener("scroll", onScroll, { passive: true });

  return {
    async update(view, selection = null) {
      const items = view.navigator.items;
      const activeFrame = view.active?.fence.surface.frame ?? view.navigator.activeFrame;
      const liveRows: HTMLElement[] = [];
      const liveThumbs: HTMLElement[] = [];
      items.forEach((item, index) => {
        const entry = ensureRow(item, index);
        // an included slide is read-only here: no interaction targets, only the badge
        const isActive = item.frame === activeFrame && view.active !== null && !item.origin;
        const plan = isActive ? view.active!.plan : item.audience;
        const key = keyOf(plan, `${isActive ? "A" : "S"}|${selection ?? ""}`);
        if (entry.key !== key) {
          entry.detach?.();
          entry.detach = paintInto(entry.slide, plan, isActive, selection);
          entry.key = key;
        }
        const notesKey = keyOf(item.notes);
        if (entry.notes.dataset.key !== notesKey) {
          entry.notes.dataset.key = notesKey;
          if (item.notes === null) {
            entry.notes.replaceChildren();
            const empty = doc.createElement("span");
            empty.className = "notes-empty";
            empty.textContent = "No notes";
            entry.notes.append(empty);
          } else paintInto(entry.notes, item.notes, false, null);
        }
        entry.row.classList.toggle("is-active-surface", isActive);
        syncOrigin(entry.slide, item);
        liveRows.push(entry.row);

        const thumb = ensureThumb(item, index);
        const thumbKey = keyOf(item.audience);
        if (thumb.key !== thumbKey) { paintInto(thumb.card, item.audience, false, null); thumb.key = thumbKey; }
        liveThumbs.push(thumb.button);
      });
      for (const [frame, r] of [...rows]) if (!items.some((i) => i.frame === frame)) { r.detach?.(); r.row.remove(); rows.delete(frame); }
      for (const [frame, t] of [...thumbs]) if (!items.some((i) => i.frame === frame)) { t.button.remove(); thumbs.delete(frame); }
      canvas.replaceChildren(...liveRows);
      rail.replaceChildren(...liveThumbs);
      markCurrent(railFrame ?? activeFrame);
      await Promise.all(settled.splice(0));
    },
    scrollToFrame,
    setShowNotes(show) { showNotes = show; canvas.dataset.notes = String(show); },
    visibleFrame: () => current,
    syncRail,
    destroy() { scroller.removeEventListener("scroll", onScroll); for (const r of rows.values()) r.detach?.(); },
  };
}
