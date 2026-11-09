/**
 * Offline deck viewer: the page produced by `sb build --html` embeds the whole-deck plan value
 * (`#sb-deck`, session/1 plans per slide and step) and this script. It only paints plans and
 * moves between them (arrows, space, click, Home/End, `f` for full screen); it never parses
 * the deck. Bundled as a single IIFE with no network access.
 */
import { ensureKatexCss } from "./content/katex-css.ts";
import { createShikiHighlighter } from "./content/highlight.ts";
import { katexProvider } from "./content/math.ts";
import { paintPlan } from "./plan/paint.ts";
import { describeOverflow, findOverflows } from "./plan/overflow.ts";
import { anchorOf, pageGeometry, printPages, type DeckSlide, type DeckValue, type PrintConfig, type RouteContinue } from "./offline-print.ts";

const highlighter = createShikiHighlighter();
const paintContext = { doc: document, math: katexProvider, highlighter, interactive: false } as const;

const doc = document;
ensureKatexCss(doc);
const root = doc.getElementById("sb-viewer") as HTMLElement;
const deck = JSON.parse(doc.getElementById("sb-deck")?.textContent ?? "{}") as DeckValue;
const slides = deck.slides ?? [];
const aspect = deck.size ? deck.size.width / deck.size.height : 16 / 9;
const printConfig = readJson<PrintConfig>("sb-print");

function readJson<T>(id: string): T | null {
  const text = doc.getElementById(id)?.textContent;
  if (text === undefined || text === null) return null;
  try { return JSON.parse(text) as T; } catch { return null; }
}

/**
 * Print layout: one `.sbv-page` per slide (final step), or per step with `steps`. The page is the
 * slide size in CSS pixels, so `@page` matches it exactly and nothing reflows between pages. Route
 * buttons become links to the first slide after the choice; the last slide of a section gets a
 * small "Continue:" line. Resolves when math/code enrichment is done.
 */
function buildPrint(steps: boolean): { readonly root: HTMLElement; readonly settled: Promise<void> } {
  const { width: pageWidth, height: pageHeight } = pageGeometry(aspect);
  const style = doc.createElement("style");
  style.textContent = `@page { size: ${pageWidth}px ${pageHeight}px; margin: 0; } .sbv-page { width: ${pageWidth}px; height: ${pageHeight}px; }`;
  const root = doc.createElement("div");
  root.className = "sbv-print";
  root.append(style);
  const pending: Promise<void>[] = [];
  for (const { slide: current, plan, first, last } of printPages(slides, deck.order, steps)) {
    const page = doc.createElement("section");
    page.className = "sbv-page";
    if (first) page.id = anchorOf(current.frame);
    const painted = paintPlan(plan, paintContext);
    pending.push(painted.settled);
    page.append(painted.element);
    for (const button of painted.element.querySelectorAll<HTMLAnchorElement>("a.sb-route")) {
      const target = current.choices?.[button.getAttribute("data-route") ?? ""];
      if (target === undefined) continue;
      button.setAttribute("href", `#${anchorOf(target)}`);
      button.removeAttribute("role");
      button.removeAttribute("tabindex");
    }
    if (last && current.continue !== undefined && current.continue.length > 0) page.append(continueLine(current.continue));
    root.append(page);
  }
  return { root, settled: Promise.all(pending).then(() => undefined) };
}

function continueLine(links: readonly RouteContinue[]): HTMLElement {
  const line = doc.createElement("div");
  line.className = "sbv-continue";
  line.append("Continue: ");
  links.forEach((link, index) => {
    if (index > 0) line.append(", ");
    const anchor = doc.createElement("a");
    anchor.setAttribute("href", `#${anchorOf(link.frame)}`);
    anchor.textContent = `${link.route}: ${link.title}`;
    line.append(anchor);
  });
  return line;
}

/** Everything is painted, fonts included: the signal a headless print waits for. */
function signalReady(settled: Promise<void>, before: () => void = () => {}): void {
  void Promise.all([settled, doc.fonts?.ready]).catch(() => undefined).then(() => {
    before();
    doc.documentElement.setAttribute("data-sb-ready", "1");
  });
}

/**
 * Out-of-bounds check for `sb build --pdf`: every step of every slide is laid out off-page, measured
 * and dropped again, and each overflow is logged as `sb-overflow: …` (the CLI reads Chrome's console
 * log and prints them as warnings). Every step, not only the printed ones, so `\only` content is checked.
 */
function overflowCheck(): { readonly settled: Promise<void>; readonly report: () => void } {
  const holder = doc.createElement("div");
  holder.setAttribute("aria-hidden", "true");
  const { width } = pageGeometry(aspect);
  holder.style.cssText = `position:absolute;top:0;left:-100000px;width:${width}px;`;
  const pending: Promise<void>[] = [];
  const painted: HTMLElement[] = [];
  for (const { plan } of printPages(slides, deck.order, true)) {
    const result = paintPlan(plan, paintContext);
    pending.push(result.settled);
    const page = doc.createElement("section");
    page.className = "sbv-page";
    page.append(result.element);
    holder.append(page);
    painted.push(result.element);
  }
  doc.body.append(holder);
  return {
    settled: Promise.all(pending).then(() => undefined),
    report: () => {
      for (const slide of painted) for (const o of findOverflows(slide)) console.warn(`sb-overflow: ${describeOverflow(o)}`);
      holder.remove();
    },
  };
}

root.className = "sbv-root";
doc.documentElement.setAttribute("data-sb-slides", String(slides.length));
const stage = doc.createElement("div");
stage.className = "sbv-stage";
const hud = doc.createElement("div");
hud.className = "sbv-hud";
root.append(stage, hud);

let slide = 0;
let step = 1;

function fit(): void {
  const w = Math.min(root.clientWidth, root.clientHeight * aspect);
  stage.style.width = `${w}px`;
}

function show(): void {
  const current = slides[slide];
  stage.replaceChildren();
  if (current === undefined) { stage.textContent = "This deck has no slides."; return; }
  const plan = current.plans[Math.min(step, current.plans.length) - 1];
  if (plan !== undefined) stage.append(paintPlan(plan, paintContext).element);
  hud.textContent = `${slide + 1} / ${slides.length}${current.steps > 1 ? `  (step ${step}/${current.steps})` : ""}`;
  doc.title = deck.title || "SlideBlaster deck";
}

function next(): void {
  const current = slides[slide];
  if (current !== undefined && step < current.steps) step += 1;
  else if (slide + 1 < slides.length) { slide += 1; step = 1; }
  show();
}
function previous(): void {
  if (step > 1) step -= 1;
  else if (slide > 0) { slide -= 1; step = slides[slide]?.steps ?? 1; }
  show();
}

doc.addEventListener("keydown", (event) => {
  switch (event.key) {
    case "ArrowRight": case "ArrowDown": case "PageDown": case " ": case "Enter": event.preventDefault(); next(); break;
    case "ArrowLeft": case "ArrowUp": case "PageUp": case "Backspace": event.preventDefault(); previous(); break;
    case "Home": slide = 0; step = 1; show(); break;
    case "End": slide = Math.max(0, slides.length - 1); step = slides[slide]?.steps ?? 1; show(); break;
    case "f": if (doc.fullscreenElement === null) void root.requestFullscreen?.(); else void doc.exitFullscreen(); break;
    default: break;
  }
});
stage.addEventListener("click", (event) => { if (event.clientX < stage.getBoundingClientRect().left + stage.clientWidth / 3) previous(); else next(); });
window.addEventListener("resize", fit);

if (printConfig !== null) {
  // `sb build --pdf`: no viewer, only the print layout.
  doc.documentElement.classList.add("sbv-printing");
  root.hidden = true;
  const printed = buildPrint(printConfig.steps);
  doc.body.append(printed.root);
  doc.title = deck.title || "SlideBlaster deck";
  const check = overflowCheck();
  signalReady(Promise.all([printed.settled, check.settled]).then(() => undefined), check.report);
} else {
  // Ctrl+P on the viewer prints the handout: build the pages when printing starts, drop them after.
  let handout: HTMLElement | null = null;
  window.addEventListener("beforeprint", () => { handout?.remove(); handout = buildPrint(false).root; doc.body.append(handout); });
  window.addEventListener("afterprint", () => { handout?.remove(); handout = null; });
  fit();
  show();
  signalReady(Promise.resolve());
}
