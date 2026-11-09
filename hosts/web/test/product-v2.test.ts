import test from "node:test";
import assert from "node:assert/strict";

import {
  base16FromBytes,
  bytesFromBase16,
  clientPointToClampedSlide,
  clientPointToSlide,
  decodeProductV2Response,
  exactCoordinate,
  ProductV2WireError,
  requestAcknowledgePaint,
  requestActivateNode,
  requestHistory,
  requestNewSlide,
  requestOpenSource,
  requestPointerEvent,
  requestReplaceSource,
  requestSelectSlide,
  requestViewCommand,
  requestWorkspaceSnapshot,
  validateProductV2Response,
} from "../src/protocol/product-v2.ts";
import * as protocol from "../src/protocol/product-v2.ts";

const encoder = new TextEncoder();
const decoder = new TextDecoder();

function surface() { return { frame: "tikz-frame", kind: "audience" }; }
function fence(overrides = {}) { return { session: 1, revision: 0, ticket: 0, surface: surface(), ...overrides }; }
function point(x, y) { return { x, y }; }
function identity(kind, id, part) { return { surface: surface(), element: { kind, id }, part }; }
function box(x = "3/2", y = "0") { return { center: point(x, y), size: { width: "2", height: "1" } }; }
function render(overrides = {}) {
  return {
    fence: fence(),
    plan: {
      protocol: "slideblaster.product/2", revision: 0, ticket: 0,
      surface: surface(), coordinateSpace: "slide_16x9_y_up",
      size: { width: "16", height: "9" },
      layers: [
        { kind: "connector", items: [{
          kind: "line", identity: identity("connector", "alpha-to-point", "path"),
          start: point("3/2", "0"), end: point("9", "8"), interaction: { kind: "inert" },
        }] },
        { kind: "object", items: [{
          kind: "rectangle", identity: identity("node", "alpha", "shape"),
          box: box(), hitTarget: box(),
          interaction: { kind: "select_element", surface: surface(), element: { kind: "node", id: "alpha" } },
        }] },
      ],
    },
    ...overrides,
  };
}
function enabled() { return { enabled: true, disabledReason: null }; }
function disabled(reason) { return { enabled: false, disabledReason: reason }; }
function workspace(overrides = {}) {
  return {
    source: { revision: 0, base16: "00ff0a" }, readiness: "ready",
    canUndo: false, canRedo: false, selection: null, authority: "paint_pending",
    renderOffer: render(), displayedRender: null,
    pointer: { phase: "idle", pointerId: null }, preview: null,
    navigator: {
      activeIndex: 0, activeFrame: "tikz-frame", slideCount: 1,
      items: [{ frame: "tikz-frame", title: "Trial", audience: render().plan, notes: null }],
      previous: disabled("only_slide_available"), next: disabled("only_slide_available"),
      newSlide: enabled(),
    },
    ...overrides,
  };
}
function success(overrides = {}) {
  return {
    protocol: "slideblaster.product/2", ok: true, kind: "source_opened",
    actions: [], workspace: workspace(), ...overrides,
  };
}
function pointerSample(type = "down", overrides = {}) {
  const sample: Record<string, any> = {
    type, pointerId: 7, pointerType: "mouse", button: 0, primary: true,
    cssPoint: point("10", "20"), slidePoint: point("3/2", "0"),
    modifiers: { alt: false, shift: false, control: false, meta: false },
    ...overrides,
  };
  if (type === "down" && sample.target === undefined) sample.target = { kind: "node", surface: surface(), nodeId: "alpha" };
  return sample;
}

test("closed success validates actions plus pointer, zoom, and navigator projections", () => {
  const value = success({
    kind: "pointer_updated",
    actions: [
      { kind: "capture_pointer", pointerId: 7 },
      { kind: "show_preview", nodeId: "alpha", centre: point("4", "5"), freeDrag: false, guides: [] },
    ],
    workspace: workspace({
      selection: "alpha", authority: "writable", renderOffer: null, displayedRender: render(),
      pointer: { phase: "dragging", pointerId: 7 },
      preview: { nodeId: "alpha", centre: point("4", "5"), freeDrag: false, guides: [], outcome: "verified" },
    }),
  });
  const decoded = validateProductV2Response(value);
  assert.deepEqual(decoded.actions.map((action) => action.kind), ["capture_pointer", "show_preview"]);
  assert.equal(decoded.workspace.pointer.phase, "dragging");
  assert.equal(decoded.workspace.navigator.previous.disabledReason, "only_slide_available");
  assert.ok(Object.isFrozen(decoded.workspace));
});

test("successful envelope and every new projection are exact-key closed", () => {
  for (const mutate of [
    (value) => { value.extra = true; },
    (value) => { delete value.actions; },
    (value) => { value.workspace.pointer.extra = true; },
    (value) => { value.workspace.navigator.previous.disabledReason = null; },
    (value) => { value.workspace.navigator.items[0].audience.extra = true; },
    (value) => { value.actions = [{ kind: "repaint", extra: true }]; },
  ]) {
    const value = structuredClone(success());
    mutate(value);
    assert.throws(() => validateProductV2Response(value), ProductV2WireError);
  }
});

test("pointer and preview correlations are validated", () => {
  assert.throws(() => validateProductV2Response(success({
    workspace: workspace({ pointer: { phase: "idle", pointerId: 7 } }),
  })), /idle pointer/);
  assert.throws(() => validateProductV2Response(success({
    workspace: workspace({ pointer: { phase: "dragging", pointerId: 7 }, preview: {
      nodeId: "alpha", centre: point("4", "5"), freeDrag: false, guides: [], outcome: "verified",
    } }),
  })), /dragging selection/);
});

test("raw pointer builders emit the frozen exact request schema", () => {
  assert.deepEqual(requestPointerEvent(pointerSample()), {
    protocol: "slideblaster.product/2", command: "pointer_event", event: pointerSample(),
  });
  assert.deepEqual(requestPointerEvent({ type: "lost_capture", pointerId: 7 }), {
    protocol: "slideblaster.product/2", command: "pointer_event",
    event: { type: "lost_capture", pointerId: 7 },
  });
  assert.deepEqual(requestPointerEvent(pointerSample("move", {
    modifiers: { alt: true, shift: false, control: false, meta: false },
  })).event.modifiers.alt, true);
  for (const invalid of [
    pointerSample("down", { extra: true }),
    pointerSample("move", { target: { kind: "canvas" } }),
    { type: "cancel", pointerId: -1 },
    pointerSample("up", { pointerType: "trackball" }),
  ]) assert.throws(() => requestPointerEvent(invalid), ProductV2WireError);
});

test("the viewport is not protocol vocabulary", () => {
  assert.equal("requestViewportEvent" in protocol, false);
  assert.throws(() => requestViewCommand("zoom_in"), ProductV2WireError);
  const withViewport: any = success();
  withViewport.workspace.zoom = { value: "1" };
  assert.throws(() => validateProductV2Response(withViewport), ProductV2WireError);
  const withViewportAction: any = success();
  withViewportAction.actions = [{ kind: "scroll_viewport_by", x: "1", y: "2" }];
  assert.throws(() => validateProductV2Response(withViewportAction), ProductV2WireError);
});

test("view, history, source, open, snapshot, and paint requests remain mechanical", () => {
  assert.deepEqual(requestActivateNode(surface(), "alpha"), {
    protocol: "slideblaster.product/2", command: "activate_node", surface: surface(), nodeId: "alpha",
  });
  assert.deepEqual(requestNewSlide(4), {
    protocol: "slideblaster.product/2", command: "new_slide", revision: 4,
  });
  assert.deepEqual(requestSelectSlide("tikz-frame"), {
    protocol: "slideblaster.product/2", command: "select_slide", frame: "tikz-frame",
  });
  assert.deepEqual(requestViewCommand("next_slide"), {
    protocol: "slideblaster.product/2", command: "view_command", viewCommand: "next_slide",
  });
  assert.deepEqual(requestHistory("undo", 4), {
    protocol: "slideblaster.product/2", command: "undo", revision: 4,
  });
  assert.deepEqual(requestReplaceSource(4, "00"), {
    protocol: "slideblaster.product/2", command: "replace_source", revision: 4, sourceBase16: "00",
  });
  assert.deepEqual(requestOpenSource("00"), {
    protocol: "slideblaster.product/2", command: "open_source", sourceBase16: "00",
  });
  assert.deepEqual(requestWorkspaceSnapshot(), {
    protocol: "slideblaster.product/2", command: "workspace_snapshot",
  });
  assert.deepEqual(requestAcknowledgePaint(fence()), {
    protocol: "slideblaster.product/2", command: "acknowledge_paint", paint: fence(),
  });
  assert.throws(() => requestViewCommand("zoom_reset"), ProductV2WireError);
});

test("all frozen action shapes are closed", () => {
  for (const action of [
    { kind: "release_pointer", pointerId: 7 },
    { kind: "focus_node", surface: surface(), nodeId: "alpha" },
    { kind: "repaint" },
    { kind: "clear_preview" },
    { kind: "show_preview", nodeId: "alpha", centre: point("8", "7"), freeDrag: true, guides: [{
      kind: "alignment", start: point("0", "7"), end: point("16", "7"),
    }] },
  ]) {
    const decoded = validateProductV2Response(success({ actions: [action] }));
    assert.equal(decoded.actions[0].kind, action.kind);
  }
  assert.throws(() => validateProductV2Response(success({ actions: [{ kind: "begin_drag" }] })), /allowed/);
});

test("malformed responses and unknown success/error values reject", () => {
  assert.throws(() => decodeProductV2Response("{"), /valid JSON/);
  assert.throws(() => validateProductV2Response(success({ kind: "drag_begun" })), /allowed/);
  assert.throws(() => validateProductV2Response({
    protocol: "slideblaster.product/2", ok: false, kind: "error",
    error: { code: "unknown", message: "redacted" },
  }), /allowed/);
});

test("base16 and exact coordinates preserve source safely", () => {
  const hostile = "</textarea><script>alert(1)</script>\r\n\tπ";
  const encoded = base16FromBytes(encoder.encode(hostile));
  assert.equal(decoder.decode(bytesFromBase16(encoded)), hostile);
  assert.deepEqual(exactCoordinate("-3/2"), { exact: "-3/2", number: -1.5 });
  for (const invalid of ["+1", "01", "1/0", "NaN"]) assert.throws(() => exactCoordinate(invalid));
});

test("actual DOM bounds convert only raw slide coordinates", () => {
  const bounds = { left: 10, right: 170, top: 20, bottom: 110, width: 160, height: 90 };
  assert.deepEqual(clientPointToSlide(10, 20, bounds), { x: "0", y: "9" });
  assert.deepEqual(clientPointToSlide(90, 65, bounds), { x: "8", y: "4.5" });
  assert.equal(clientPointToSlide(9, 20, bounds), null);
  assert.deepEqual(clientPointToClampedSlide(9, 120, bounds), { x: "0", y: "0" });
  assert.deepEqual(clientPointToClampedSlide(200, 10, bounds), { x: "16", y: "9" });
});
