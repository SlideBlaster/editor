/**
 * Free zoom for the deck column, as in a PDF viewer: pinch, Ctrl+wheel, Ctrl+plus/minus/0 and the
 * zoom buttons scale the whole deck about the pointer (or the view centre), and middle-drag pans.
 * The deck is laid out once at its unzoomed width and only *painted* bigger (a CSS transform), so
 * zooming never reflows slides; a sizer element gives the scroller the zoomed extent, so the
 * ordinary scrollbars and wheel scrolling pan the zoomed deck.
 */

export const minimumZoom = 0.25;
export const maximumZoom = 6;
/** One button press or keyboard step. */
export const zoomStep = 1.25;

export function clampZoom(zoom: number): number {
  if (!Number.isFinite(zoom)) return 1;
  return Math.min(maximumZoom, Math.max(minimumZoom, zoom));
}

/**
 * Zoom factor for one Ctrl+wheel event. Pinch gestures arrive as many small pixel deltas, a mouse
 * notch as one large one (or a line delta); capping the per-event delta keeps a notch to ~35%.
 */
export function wheelFactor(deltaY: number, deltaMode: number): number {
  const pixels = deltaMode === 1 ? deltaY * 33 : deltaMode === 2 ? deltaY * 800 : deltaY;
  return Math.exp(-Math.max(-30, Math.min(30, pixels)) * 0.01);
}

/** Left inset that centres content narrower than the view (zoomed out). */
export function centring(viewWidth: number, contentWidth: number): number {
  return Math.max(0, (viewWidth - contentWidth) / 2);
}

/**
 * Scroll position after a zoom change that keeps the content point under `focal` (pixels from the
 * scroller's top-left) where it is. `scroll` and `inset` are before, `nextInset` after.
 */
export function anchoredScroll(scroll: number, focal: number, inset: number, zoom: number, nextInset: number, nextZoom: number): number {
  const content = (scroll + focal - inset) / zoom;
  return Math.max(0, content * nextZoom + nextInset - focal);
}

export interface FreeZoom {
  readonly zoom: () => number;
  /** Zoom to `next`, keeping the point at client (x, y) fixed; the view centre by default. */
  readonly zoomTo: (next: number, clientX?: number, clientY?: number) => void;
  readonly zoomBy: (factor: number, clientX?: number, clientY?: number) => void;
}

export function installFreeZoom(options: {
  readonly scroller: HTMLElement;
  readonly canvas: HTMLElement;
  readonly onChange?: (zoom: number) => void;
}): FreeZoom {
  const { scroller, canvas } = options;
  const doc = scroller.ownerDocument;
  const sizer = doc.createElement("div");
  sizer.className = "deck-zoom-sizer";
  sizer.style.cssText = "position:relative;overflow:hidden;";
  canvas.before(sizer);
  sizer.append(canvas);
  canvas.style.position = "absolute";
  canvas.style.top = "0";
  canvas.style.left = "0";
  canvas.style.transformOrigin = "0 0";
  canvas.style.minWidth = "0"; // its stylesheet min-width (100%) would now follow the zoomed sizer

  let zoom = 1;
  let baseWidth = 0;
  let inset = 0;

  const layout = (): void => {
    const width = canvas.offsetWidth;
    const height = canvas.offsetHeight;
    inset = centring(scroller.clientWidth, width * zoom);
    sizer.style.width = `${Math.max(scroller.clientWidth, width * zoom)}px`;
    sizer.style.height = `${height * zoom}px`;
    canvas.style.transform = `translate(${inset}px, 0) scale(${zoom})`;
  };
  // The deck lays out at the view width, as without zoom; only resizing the view changes it.
  const fitBase = (): void => {
    const width = scroller.clientWidth;
    if (width === baseWidth) return;
    baseWidth = width;
    canvas.style.width = `${width}px`;
  };
  fitBase();
  layout();
  if (typeof ResizeObserver === "function") {
    new ResizeObserver(() => { fitBase(); layout(); }).observe(scroller);
    new ResizeObserver(() => layout()).observe(canvas);
  }

  const zoomTo = (next: number, clientX?: number, clientY?: number): void => {
    const target = clampZoom(next);
    if (target === zoom) return;
    const box = scroller.getBoundingClientRect();
    const fx = clientX === undefined ? scroller.clientWidth / 2 : clientX - box.left;
    const fy = clientY === undefined ? scroller.clientHeight / 2 : clientY - box.top;
    const before = { zoom, inset, left: scroller.scrollLeft, top: scroller.scrollTop };
    zoom = target;
    layout();
    scroller.scrollLeft = anchoredScroll(before.left, fx, before.inset, before.zoom, inset, zoom);
    scroller.scrollTop = anchoredScroll(before.top, fy, 0, before.zoom, 0, zoom);
    options.onChange?.(zoom);
  };
  const zoomBy = (factor: number, clientX?: number, clientY?: number): void => zoomTo(zoom * factor, clientX, clientY);

  // Pinch (Chrome, WebKitGTK) and Ctrl+wheel arrive as wheel events with ctrlKey.
  scroller.addEventListener("wheel", (event) => {
    if (!event.ctrlKey && !event.metaKey) return;
    event.preventDefault();
    zoomBy(wheelFactor(event.deltaY, event.deltaMode), event.clientX, event.clientY);
  }, { passive: false });
  // Safari-style gesture events (WebKit): scale is relative to the gesture start.
  let gestureStart = 1;
  type Gesture = Event & { readonly scale: number; readonly clientX: number; readonly clientY: number };
  scroller.addEventListener("gesturestart", (event) => { event.preventDefault(); gestureStart = zoom; });
  scroller.addEventListener("gesturechange", (event) => {
    event.preventDefault();
    const g = event as Gesture;
    zoomTo(gestureStart * g.scale, g.clientX, g.clientY);
  });
  doc.addEventListener("keydown", (event) => {
    if (!(event.ctrlKey || event.metaKey) || event.altKey) return;
    if (event.key === "+" || event.key === "=") { event.preventDefault(); zoomBy(zoomStep); }
    else if (event.key === "-") { event.preventDefault(); zoomBy(1 / zoomStep); }
    else if (event.key === "0") { event.preventDefault(); zoomTo(1); }
  });
  // Middle-drag pans in both directions, at any zoom.
  scroller.addEventListener("pointerdown", (event) => {
    if (event.button !== 1) return;
    event.preventDefault();
    const start = { x: event.clientX, y: event.clientY, left: scroller.scrollLeft, top: scroller.scrollTop };
    scroller.setPointerCapture(event.pointerId);
    scroller.style.cursor = "grabbing";
    const move = (e: PointerEvent): void => {
      scroller.scrollLeft = start.left - (e.clientX - start.x);
      scroller.scrollTop = start.top - (e.clientY - start.y);
    };
    const end = (): void => {
      scroller.style.cursor = "";
      scroller.removeEventListener("pointermove", move);
      scroller.removeEventListener("pointerup", end);
      scroller.removeEventListener("pointercancel", end);
    };
    scroller.addEventListener("pointermove", move);
    scroller.addEventListener("pointerup", end);
    scroller.addEventListener("pointercancel", end);
  });
  // Middle-click would otherwise start autoscroll (or paste on Linux).
  scroller.addEventListener("auxclick", (event) => { if (event.button === 1) event.preventDefault(); });

  return { zoom: () => zoom, zoomTo, zoomBy };
}
