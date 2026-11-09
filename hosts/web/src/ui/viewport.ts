/**
 * Local browser viewport for the deck canvas.
 *
 * Which part of the canvas is shown is presentation state that belongs to the
 * browser, so zoom and pan are owned here and never cross the Product/2
 * boundary. Every gesture updates plain numbers and writes one composited
 * `transform`, which keeps interaction at input rate instead of waiting for a
 * runtime round trip and a slide relayout.
 *
 * Source bytes, revisions, history, selection, and node geometry remain
 * Haskell-owned; this module never reads or writes them.
 *
 * Layout stays at unit scale. `scale()` is a paint-time transform, so zooming
 * does not resize slides, reflow the deck, or invalidate rendered surfaces.
 * Element bounding rectangles remain the single coordinate authority for
 * pointer work, so node dragging stays exact at any zoom.
 */

const MINIMUM_ZOOM = 1 / 4;
const MAXIMUM_ZOOM = 6;
const ZOOM_STEP = 23 / 20;
const FIT_MARGIN = 49 / 50;
const LINE_PIXELS = 16;
const MAXIMUM_WHEEL_FACTOR = 27 / 20;
const WHEEL_SENSITIVITY = 0.0014;
const REVEAL_MARGIN = 24;

export const viewportLimits = Object.freeze({
  minimum: MINIMUM_ZOOM,
  maximum: MAXIMUM_ZOOM,
  step: ZOOM_STEP,
  fitMargin: FIT_MARGIN,
});

/**
 * @param {number} zoom
 * @returns {number}
 */
export function clampZoom(zoom) {
  if (!Number.isFinite(zoom)) return 1;
  return Math.min(MAXIMUM_ZOOM, Math.max(MINIMUM_ZOOM, zoom));
}

/**
 * Convert a wheel delta to pixels using the browser's own unit report.
 *
 * @param {number} delta
 * @param {number} deltaMode
 * @param {number} pageLength
 * @returns {number}
 */
export function wheelPixels(delta, deltaMode, pageLength) {
  if (!Number.isFinite(delta)) return 0;
  if (deltaMode === 1) return delta * LINE_PIXELS;
  if (deltaMode === 2) return delta * pageLength;
  return delta;
}

/**
 * Continuous per-sample zoom factor. Trackpads and mice deliver very different
 * magnitudes, so the factor is exponential in the pixel delta and clamped so a
 * single coarse notch cannot jump the whole zoom range.
 *
 * @param {number} pixels
 * @returns {number}
 */
export function wheelZoomFactor(pixels) {
  const raw = Math.exp(-pixels * WHEEL_SENSITIVITY);
  return Math.min(MAXIMUM_WHEEL_FACTOR, Math.max(1 / MAXIMUM_WHEEL_FACTOR, raw));
}

/**
 * Offset that keeps the content point under `focal` stationary across a zoom
 * change. Derived from `screen = offset + content * zoom`.
 *
 * @param {number} offset
 * @param {number} focal
 * @param {number} previousZoom
 * @param {number} nextZoom
 * @returns {number}
 */
export function focalOffset(offset, focal, previousZoom, nextZoom) {
  if (previousZoom <= 0) return offset;
  return focal - (focal - offset) * (nextZoom / previousZoom);
}

/**
 * Keep scaled content reachable: centre it while it is smaller than the
 * viewport, otherwise forbid gaps at either edge.
 *
 * @param {number} offset
 * @param {number} viewportLength
 * @param {number} scaledLength
 * @returns {number}
 */
export function clampOffset(offset, viewportLength, scaledLength) {
  if (scaledLength <= viewportLength) return (viewportLength - scaledLength) / 2;
  return Math.min(0, Math.max(viewportLength - scaledLength, offset));
}

/**
 * Smallest offset change that brings a scaled span inside the viewport.
 *
 * @param {number} offset
 * @param {number} start
 * @param {number} length
 * @param {number} viewportLength
 * @returns {number}
 */
export function revealOffset(offset, start, length, viewportLength) {
  const visibleStart = start + offset;
  const visibleEnd = visibleStart + length;
  if (visibleStart < REVEAL_MARGIN) return REVEAL_MARGIN - start;
  if (visibleEnd > viewportLength - REVEAL_MARGIN) {
    return viewportLength - REVEAL_MARGIN - length - start;
  }
  return offset;
}

/**
 * @param {number} viewportWidth
 * @param {number} slideWidth
 * @returns {number}
 */
export function fitWidthZoom(viewportWidth, slideWidth) {
  if (!(slideWidth > 0) || !(viewportWidth > 0)) return 1;
  return clampZoom((viewportWidth * FIT_MARGIN) / slideWidth);
}

/**
 * Bind a canvas viewport to a clipping frame and its transformed content.
 *
 * @param {object} parameters
 * @param {HTMLElement} parameters.frame Clipping element that shows the canvas.
 * @param {HTMLElement} parameters.canvas Transformed, unit-scale content.
 * @param {() => (HTMLElement | null)} parameters.activeSlide
 * @param {() => void} [parameters.onChange]
 */
export function createCanvasViewport({ frame, canvas, activeSlide, onChange = () => {} }) {
  let zoom = 1;
  let offsetX = 0;
  let offsetY = 0;
  let moved = false;
  let panPointerId = null;
  let panX = 0;
  let panY = 0;
  let spaceHeld = false;
  let frameMetrics = { left: 0, top: 0, width: 0, height: 0 };
  let contentMetrics = { width: 0, height: 0 };

  measure();
  if (typeof ResizeObserver === "function") {
    new ResizeObserver(() => {
      measure();
      commit();
    }).observe(frame);
  }

  /**
   * Re-read the frame position and unit-scale content size. Called only when
   * layout can actually have changed, so gestures perform no layout reads.
   */
  function measure() {
    const bounds = frame.getBoundingClientRect();
    frameMetrics = {
      left: bounds.left,
      top: bounds.top,
      width: frame.clientWidth,
      height: frame.clientHeight,
    };
    contentMetrics = { width: canvas.offsetWidth, height: canvas.offsetHeight };
  }

  function commit() {
    offsetX = clampOffset(offsetX, frameMetrics.width, contentMetrics.width * zoom);
    offsetY = clampOffset(offsetY, frameMetrics.height, contentMetrics.height * zoom);
    canvas.style.transform = `translate(${offsetX}px, ${offsetY}px) scale(${zoom})`;
    onChange();
  }

  /**
   * @param {number} nextZoom
   * @param {number} clientX
   * @param {number} clientY
   */
  function zoomTo(nextZoom, clientX, clientY) {
    const target = clampZoom(nextZoom);
    if (target === zoom) return;
    offsetX = focalOffset(offsetX, clientX - frameMetrics.left, zoom, target);
    offsetY = focalOffset(offsetY, clientY - frameMetrics.top, zoom, target);
    zoom = target;
    moved = true;
    commit();
  }

  function zoomToCentre(nextZoom) {
    zoomTo(
      nextZoom,
      frameMetrics.left + frameMetrics.width / 2,
      frameMetrics.top + frameMetrics.height / 2,
    );
  }

  /** @returns {{left: number, top: number, width: number, height: number} | null} */
  function activeSlideMetrics() {
    const slide = activeSlide();
    if (slide === null || slide === undefined) return null;
    return {
      left: slide.offsetLeft,
      top: slide.offsetTop,
      width: slide.offsetWidth,
      height: slide.offsetHeight,
    };
  }

  function home() {
    const slide = activeSlideMetrics();
    if (slide === null) {
      offsetX = 0;
      offsetY = 0;
      return;
    }
    offsetX = (frameMetrics.width - slide.width * zoom) / 2 - slide.left * zoom;
    offsetY = REVEAL_MARGIN - slide.top * zoom;
  }

  return {
    /** Re-measure after the deck structure or layout changed. */
    measure() {
      measure();
      commit();
    },

    /**
     * Zoom about the pointer for Ctrl/Cmd wheel and trackpad pinch.
     *
     * @param {WheelEvent} event
     */
    zoomByWheel(event) {
      const pixels = wheelPixels(event.deltaY, event.deltaMode, frameMetrics.height);
      zoomTo(zoom * wheelZoomFactor(pixels), event.clientX, event.clientY);
    },

    /**
     * Plain wheel and trackpad scrolling moves the canvas.
     *
     * @param {WheelEvent} event
     */
    panByWheel(event) {
      const x = wheelPixels(event.deltaX, event.deltaMode, frameMetrics.width);
      const y = wheelPixels(event.deltaY, event.deltaMode, frameMetrics.height);
      if (x === 0 && y === 0) return;
      if (event.shiftKey && x === 0) offsetX -= y;
      else {
        offsetX -= x;
        offsetY -= y;
      }
      moved = true;
      commit();
    },

    /**
     * @param {"in" | "out" | "reset" | "fit_width"} command
     */
    applyZoomCommand(command) {
      if (command === "in") return zoomToCentre(zoom * ZOOM_STEP);
      if (command === "out") return zoomToCentre(zoom / ZOOM_STEP);
      if (command === "reset") {
        zoom = 1;
        home();
        moved = false;
        return commit();
      }
      const slide = activeSlideMetrics();
      if (slide === null) return;
      zoom = fitWidthZoom(frameMetrics.width, slide.width);
      home();
      moved = true;
      return commit();
    },

    /**
     * @param {PointerEvent} event
     * @returns {boolean} whether the event begins a pan
     */
    beginPan(event) {
      if (panPointerId !== null) return false;
      const eligible = event.button === 1 || (event.button === 0 && spaceHeld);
      if (!eligible) return false;
      panPointerId = event.pointerId;
      panX = event.clientX;
      panY = event.clientY;
      frame.classList.add("is-panning");
      try {
        frame.setPointerCapture(event.pointerId);
      } catch {
        // Synthetic or already-released pointers may not be capturable.
      }
      return true;
    },

    /**
     * @param {PointerEvent} event
     * @returns {boolean} whether the event was consumed by panning
     */
    continuePan(event) {
      if (panPointerId !== event.pointerId) return false;
      offsetX += event.clientX - panX;
      offsetY += event.clientY - panY;
      panX = event.clientX;
      panY = event.clientY;
      moved = true;
      commit();
      return true;
    },

    /**
     * @param {number} pointerId
     * @returns {boolean} whether a pan ended
     */
    endPan(pointerId) {
      if (panPointerId !== pointerId) return false;
      panPointerId = null;
      frame.classList.remove("is-panning");
      if (frame.hasPointerCapture(pointerId)) frame.releasePointerCapture(pointerId);
      return true;
    },

    /** @param {boolean} held */
    setSpaceHeld(held) {
      if (spaceHeld === held) return;
      spaceHeld = held;
      frame.classList.toggle("space-held", held);
    },

    /** Bring the active slide into view without disturbing the current zoom. */
    revealActiveSlide() {
      const slide = activeSlideMetrics();
      if (slide === null) return;
      offsetX = revealOffset(offsetX, slide.left * zoom, slide.width * zoom, frameMetrics.width);
      offsetY = revealOffset(offsetY, slide.top * zoom, slide.height * zoom, frameMetrics.height);
      commit();
    },

    /** Presentation-only state for projection and acceptance evidence. */
    state() {
      return {
        zoom,
        offsetX,
        offsetY,
        panning: panPointerId !== null,
        canZoomIn: zoom < MAXIMUM_ZOOM,
        canZoomOut: zoom > MINIMUM_ZOOM,
        canReset: zoom !== 1 || moved,
      };
    },
  };
}
