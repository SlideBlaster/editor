/**
 * Pure part of the offline viewer's print layout: which pages a deck prints, in which order,
 * and how big a page is. No DOM, so it runs under `node --test`.
 */
import type { Plan } from "./protocol/plan.ts";

export interface RouteContinue { readonly route: string; readonly title: string; readonly frame: string }
export interface DeckSlide {
  readonly frame: string; readonly title: string; readonly steps: number; readonly plans: readonly Plan[];
  /** Route choice buttons on this slide: route id to the first frame after the choice on that route. */
  readonly choices?: Readonly<Record<string, string>>;
  /** Last slide of a section: the routes that continue elsewhere, one link each. */
  readonly continue?: readonly RouteContinue[];
}
export interface DeckValue {
  readonly title: string; readonly size: { readonly width: number; readonly height: number }; readonly slides: readonly DeckSlide[];
  /** Frame ids in print order (default route, each section once). */
  readonly order?: readonly string[];
}
export interface PrintConfig { readonly steps: boolean }


/** Slides in print order: `order` when present, then any slide it does not name. */
export function printOrder(all: readonly DeckSlide[], order: readonly string[] | undefined): readonly DeckSlide[] {
  if (order === undefined) return all;
  const byFrame = new Map(all.map((s) => [s.frame, s] as const));
  const named = order.flatMap((frame) => { const s = byFrame.get(frame); return s === undefined ? [] : [s]; });
  const seen = new Set(named);
  return [...named, ...all.filter((s) => !seen.has(s))];
}

/** Anchor id of a slide's first page (internal PDF links target it). */
export const anchorOf = (frame: string): string => `sbframe-${frame}`;

export interface PrintPage { readonly slide: DeckSlide; readonly plan: Plan; readonly first: boolean; readonly last: boolean }

/** One page per slide showing its final step, or per step with `steps`. */
export function printPages(all: readonly DeckSlide[], order: readonly string[] | undefined, steps: boolean): readonly PrintPage[] {
  return printOrder(all, order).flatMap((slide) => {
    const plans = steps ? slide.plans : slide.plans.slice(-1);
    return plans.map((plan, index) => ({ slide, plan, first: index === 0, last: index === plans.length - 1 }));
  });
}

/** Page box in CSS pixels: 960 wide (254 mm), height from the slide aspect. */
export function pageGeometry(aspect: number): { readonly width: number; readonly height: number } {
  return { width: 960, height: Math.round((960 / aspect) * 1000) / 1000 };
}
