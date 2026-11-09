import test from "node:test";
import assert from "node:assert/strict";

import {
  clampOffset,
  clampZoom,
  createCanvasViewport,
  fitWidthZoom,
  focalOffset,
  revealOffset,
  viewportLimits,
  wheelPixels,
  wheelZoomFactor,
} from "../src/ui/viewport.ts";

test("zoom stays inside the presentation bounds", () => {
  assert.equal(clampZoom(1), 1);
  assert.equal(clampZoom(0.01), viewportLimits.minimum);
  assert.equal(clampZoom(99), viewportLimits.maximum);
  assert.equal(clampZoom(Number.NaN), 1);
});

test("wheel deltas are converted with the browser's own unit report", () => {
  assert.equal(wheelPixels(3, 0, 800), 3);
  assert.equal(wheelPixels(3, 1, 800), 48);
  assert.equal(wheelPixels(0.5, 2, 800), 400);
  assert.equal(wheelPixels(Number.NaN, 0, 800), 0);
});

test("a single wheel sample cannot jump the whole zoom range", () => {
  assert(wheelZoomFactor(-4) > 1, "scrolling up magnifies");
  assert(wheelZoomFactor(4) < 1, "scrolling down reduces");
  assert.equal(wheelZoomFactor(-100000), 27 / 20);
  assert.equal(wheelZoomFactor(100000), 20 / 27);
  const fine = wheelZoomFactor(-2);
  const coarse = wheelZoomFactor(-120);
  assert(fine < coarse, "a coarse notch must zoom more than a trackpad sample");
});

test("the focal content point is stationary across a zoom change", () => {
  const zoom = 1.4;
  const next = zoom * 1.15;
  const offset = -260;
  const focal = 430;
  const content = (focal - offset) / zoom;
  const moved = focalOffset(offset, focal, zoom, next);
  assert(Math.abs(moved + content * next - focal) < 1e-9);
});

test("content is centred while small and edge-locked while large", () => {
  assert.equal(clampOffset(-90, 900, 300), 300);
  assert.equal(clampOffset(50, 900, 1500), 0);
  assert.equal(clampOffset(-5000, 900, 1500), -600);
  assert.equal(clampOffset(-100, 900, 1500), -100);
});

test("reveal moves the smallest distance that shows a span", () => {
  assert.equal(revealOffset(-40, 0, 200, 900), 24);
  assert.equal(revealOffset(0, 1200, 200, 900), 900 - 24 - 200 - 1200);
  assert.equal(revealOffset(-100, 200, 300, 900), -100);
});

test("fit width leaves the accepted margin and respects bounds", () => {
  assert.equal(fitWidthZoom(1000, 500), (1000 * 49) / 50 / 500);
  assert.equal(fitWidthZoom(100000, 500), viewportLimits.maximum);
  assert.equal(fitWidthZoom(900, 0), 1);
});

test("a wheel burst applies every sample synchronously without a round trip", () => {
  const harness = createHarness();
  const before = harness.viewport.state().zoom;
  for (let sample = 0; sample < 40; sample += 1) {
    harness.viewport.zoomByWheel(wheelEvent({ deltaY: -4, clientX: 500, clientY: 400 }));
  }
  const after = harness.viewport.state().zoom;
  assert(Math.abs(after - before * wheelZoomFactor(-4) ** 40) < 1e-9);
  assert.equal(harness.transforms.length, 40, "each sample writes exactly one transform");
  assert.match(harness.canvas.style.transform, /^translate\(-?[\d.]+px, -?[\d.]+px\) scale\([\d.]+\)$/);
});

test("pointer-anchored wheel zoom keeps the pointed content under the pointer", () => {
  const harness = createHarness();
  const focal = { clientX: 640, clientY: 520 };
  const local = { x: focal.clientX - harness.frameLeft, y: focal.clientY - harness.frameTop };
  const before = harness.viewport.state();
  const content = {
    x: (local.x - before.offsetX) / before.zoom,
    y: (local.y - before.offsetY) / before.zoom,
  };
  harness.viewport.zoomByWheel(wheelEvent({ deltaY: -240, ...focal }));
  const after = harness.viewport.state();
  assert(after.zoom > before.zoom);
  assert(Math.abs(after.offsetX + content.x * after.zoom - local.x) < 1e-9);
  assert(Math.abs(after.offsetY + content.y * after.zoom - local.y) < 1e-9);
});

test("middle-button and Space panning translate the canvas and release capture", () => {
  const harness = createHarness();
  harness.viewport.applyZoomCommand("in");
  const before = harness.viewport.state();

  assert.equal(harness.viewport.beginPan(pointerEvent({ pointerId: 7, button: 0 })), false);
  assert.equal(harness.viewport.beginPan(pointerEvent({ pointerId: 7, button: 1 })), true);
  assert.equal(harness.viewport.state().panning, true);
  assert.equal(harness.viewport.continuePan(pointerEvent({ pointerId: 7, clientX: 400 - 90, clientY: 300 - 70 })), true);
  const panned = harness.viewport.state();
  assert.equal(panned.offsetX, before.offsetX - 90);
  assert.equal(panned.offsetY, before.offsetY - 70);
  assert.equal(harness.viewport.endPan(7), true);
  assert.equal(harness.viewport.state().panning, false);
  assert.deepEqual(harness.released, [7]);

  harness.viewport.setSpaceHeld(true);
  assert.equal(harness.viewport.beginPan(pointerEvent({ pointerId: 8, button: 0 })), true);
  assert.equal(harness.viewport.endPan(8), true);
  harness.viewport.setSpaceHeld(false);
});

test("zoom commands stay centred and reset returns to the unit view", () => {
  const harness = createHarness();
  harness.viewport.applyZoomCommand("in");
  assert.equal(harness.viewport.state().zoom, 23 / 20);
  harness.viewport.applyZoomCommand("out");
  assert(Math.abs(harness.viewport.state().zoom - 1) < 1e-12);

  harness.viewport.applyZoomCommand("fit_width");
  const fitted = harness.viewport.state();
  assert.equal(fitted.zoom, fitWidthZoom(harness.frameWidth, 700));
  assert.equal(fitted.canReset, true);

  harness.viewport.applyZoomCommand("reset");
  const reset = harness.viewport.state();
  assert.equal(reset.zoom, 1);
  assert.equal(reset.canReset, false);
});

function createHarness() {
  const transforms: any[] = [];
  const released: any[] = [];
  const frameLeft = 300;
  const frameTop = 100;
  const frameWidth = 900;
  const frameHeight = 800;
  const canvas = {
    style: new Proxy<any>({}, {
      set(target, property, value) {
        if (property === "transform") transforms.push(value);
        target[property] = value;
        return true;
      },
    }),
    offsetWidth: 1040,
    offsetHeight: 1400,
  };
  const slide = { offsetLeft: 32, offsetTop: 32, offsetWidth: 700, offsetHeight: 394 };
  const frame = {
    clientWidth: frameWidth,
    clientHeight: frameHeight,
    getBoundingClientRect: () => ({ left: frameLeft, top: frameTop, width: frameWidth, height: frameHeight }),
    classList: { add() {}, remove() {}, toggle() {} },
    setPointerCapture() {},
    hasPointerCapture: () => true,
    releasePointerCapture: (pointerId) => released.push(pointerId),
  };
  const viewport = createCanvasViewport({ frame, canvas, activeSlide: () => slide });
  viewport.measure();
  transforms.length = 0;
  return { viewport, canvas, transforms, released, frameLeft, frameTop, frameWidth, frameHeight };
}

function wheelEvent({ deltaY, clientX, clientY, deltaX = 0, deltaMode = 0, shiftKey = false }) {
  return { deltaX, deltaY, deltaMode, clientX, clientY, shiftKey };
}

function pointerEvent({ pointerId, button = 0, clientX = 400, clientY = 300 }) {
  return { pointerId, button, clientX, clientY, isPrimary: true };
}
