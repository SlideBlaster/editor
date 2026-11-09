import {
  clientPointToClampedSlide,
  clientPointToSlide,
} from "../protocol/product-v2.ts";
import { createPointerEventTransport } from "./pointer-event-transport.ts";

const svgNamespace = "http://www.w3.org/2000/svg";
const slideWidth = 16;
const slideHeight = 9;

/**
 * Paint one validated Haskell render projection and report raw DOM pointer
 * facts. This adapter has no gesture phase, threshold, selection, or snap rule.
 */
export function createProductV2RenderSurface(correlated, options) {
  if (typeof options?.onPointerEvent !== "function") {
    throw new TypeError("Product/2 renderer requires onPointerEvent");
  }
  if (typeof options?.onNodeActivation !== "function") {
    throw new TypeError("Product/2 renderer requires onNodeActivation");
  }
  const ownerDocument = options.ownerDocument ?? document;
  const root = ownerDocument.createElement("section");
  root.className = "product-v2-render-surface";
  root.dataset.revision = String(correlated.fence.revision);
  root.dataset.session = String(correlated.fence.session);
  root.dataset.ticket = String(correlated.fence.ticket);
  root.dataset.lease = "inert";
  root.setAttribute("aria-label", "Source-authoritative slide canvas");
  root.setAttribute("aria-disabled", "true");
  root.setAttribute("inert", "");

  const geometry = svg(ownerDocument, "product-v2-geometry");
  geometry.setAttribute("aria-hidden", "true");
  const yUp = ownerDocument.createElementNS(svgNamespace, "g");
  yUp.setAttribute("transform", "translate(0 9) scale(1 -1)");
  geometry.append(yUp);

  const targets = ownerDocument.createElement("div");
  targets.className = "product-v2-targets";
  const overlay = svg(ownerDocument, "product-v2-overlay");
  overlay.setAttribute("aria-hidden", "true");
  const overlayYUp = ownerDocument.createElementNS(svgNamespace, "g");
  overlayYUp.setAttribute("transform", "translate(0 9) scale(1 -1)");
  const selectionLayer = ownerDocument.createElementNS(svgNamespace, "g");
  const guideLayer = ownerDocument.createElementNS(svgNamespace, "g");
  selectionLayer.classList.add("product-v2-selection-layer");
  guideLayer.classList.add("product-v2-guide-layer");
  overlayYUp.append(selectionLayer, guideLayer);
  overlay.append(overlayYUp);

  const guideStatus = ownerDocument.createElement("span");
  guideStatus.className = "visually-hidden product-v2-guide-status";
  guideStatus.setAttribute("role", "status");
  guideStatus.setAttribute("aria-live", "polite");
  guideStatus.textContent = "";

  const nodeItems: any[] = [];
  for (const layer of correlated.plan.layers) {
    for (const item of layer.items) {
      if (item.kind === "line") yUp.append(createLine(ownerDocument, item));
      else {
        yUp.append(createRectangle(ownerDocument, item));
        nodeItems.push(item);
      }
    }
  }

  for (const item of nodeItems) {
    targets.append(createTarget(ownerDocument, item));
  }
  root.append(geometry, targets, overlay, guideStatus);

  const pointerTargets = new Map<number, any>();
  const trackedPointerIds = new Set();
  const pendingMoves = new Map();
  const suppressedLostCapture = new Set();
  const pointerTransport = createPointerEventTransport(options.onPointerEvent);
  let animationFrame = null;
  let deactivated = false;
  let selection = options.selection ?? null;
  let previewGhost: any = null;
  renderSelection();

  root.addEventListener("dragstart", (event) => event.preventDefault());
  root.addEventListener("pointerdown", (event) => {
    const target = event.target.closest?.(".product-v2-node-target") ?? null;
    const captureTarget = target ?? root;
    const pointerTarget = target === null
      ? { kind: "canvas" }
      : { kind: "node", surface: correlated.fence.surface, nodeId: target.dataset.nodeId };
    const fact = sampleFact("down", event, pointerTarget);
    if (fact !== null) {
      trackedPointerIds.add(event.pointerId);
      pointerTransport.begin(fact, () => {
        if (deactivated) return;
        pointerTargets.set(event.pointerId, captureTarget);
        if (event.isPrimary && !captureTarget.hasPointerCapture(event.pointerId)) {
          try {
            captureTarget.setPointerCapture(event.pointerId);
          } catch {
            // Synthetic events and unsupported devices may have no capturable pointer.
          }
        }
      });
    }
    event.preventDefault();
  }, true);
  root.addEventListener("keydown", (event) => {
    const target = (event.target as Element).closest?.(".product-v2-node-target") as HTMLElement | null ?? null;
    if (target === null || (event.key !== "Enter" && event.key !== " ")) return;
    event.preventDefault();
    options.onNodeActivation(correlated.fence.surface, target.dataset.nodeId);
  }, true);
  root.addEventListener("pointermove", (event) => {
    const fact = sampleFact("move", event, undefined);
    if (fact === null) return;
    pendingMoves.set(event.pointerId, fact);
    if (animationFrame === null) {
      animationFrame = ownerDocument.defaultView!.requestAnimationFrame(flushMoves);
    }
    event.preventDefault();
  }, true);
  root.addEventListener("pointerup", (event) => {
    discardPointerMove(event.pointerId);
    const fact = sampleFact("up", event, undefined, true);
    if (fact !== null) {
      pointerTransport.finish(event.pointerId, { ...fact, type: "move" }, fact);
    } else {
      pointerTransport.cancel(event.pointerId, { type: "cancel", pointerId: event.pointerId });
    }
    event.preventDefault();
  }, true);
  root.addEventListener("pointercancel", (event) => {
    discardPointerMove(event.pointerId);
    pointerTransport.cancel(event.pointerId, { type: "cancel", pointerId: event.pointerId });
    event.preventDefault();
  }, true);
  root.addEventListener("lostpointercapture", (event) => {
    if (
      suppressedLostCapture.delete(event.pointerId)
      || pointerTransport.isTerminal(event.pointerId)
      || pointerTransport.isSettling(event.pointerId)
    ) return;
    discardPointerMove(event.pointerId);
    pointerTransport.cancel(event.pointerId, { type: "lost_capture", pointerId: event.pointerId });
  }, true);

  function sampleFact(type, event, target, clampToSlide = false) {
    const bounds = snapshotBounds(root.getBoundingClientRect());
    const slidePoint = clampToSlide
      ? clientPointToClampedSlide(event.clientX, event.clientY, bounds)
      : clientPointToSlide(event.clientX, event.clientY, bounds);
    if (slidePoint === null) return null;
    const fact: Record<string, any> = {
      type,
      pointerId: event.pointerId,
      pointerType: event.pointerType,
      button: domButtonFact(event),
      primary: event.isPrimary,
      cssPoint: { x: decimalFact(event.clientX), y: decimalFact(event.clientY) },
      slidePoint,
      modifiers: {
        alt: event.altKey,
        shift: event.shiftKey,
        control: event.ctrlKey,
        meta: event.metaKey,
      },
    };
    if (target !== undefined) fact.target = target;
    return fact;
  }

  function flushMoves() {
    animationFrame = null;
    const retained = [...pendingMoves.values()];
    pendingMoves.clear();
    for (const fact of retained) pointerTransport.move(fact);
  }

  function discardPointerMove(pointerId) {
    pendingMoves.delete(pointerId);
  }

  function executeAction(action) {
    if (action.kind === "capture_pointer") {
      const target = pointerTargets.get(action.pointerId);
      if (target !== undefined && !target.hasPointerCapture(action.pointerId)) {
        try { target.setPointerCapture(action.pointerId); } catch { /* Synthetic input may have no native capture. */ }
      }
    } else if (action.kind === "release_pointer") {
      const target = pointerTargets.get(action.pointerId);
      pointerTargets.delete(action.pointerId);
      trackedPointerIds.delete(action.pointerId);
      if (target !== undefined && target.hasPointerCapture(action.pointerId)) {
        suppressedLostCapture.add(action.pointerId);
        target.releasePointerCapture(action.pointerId);
      }
    } else if (action.kind === "focus_node") {
      const target = targets.querySelector(`[data-node-id="${CSS.escape(action.nodeId)}"]`);
      target?.focus({ preventScroll: true });
    } else if (action.kind === "show_preview") {
      paintPreview(action);
    } else if (action.kind === "clear_preview") {
      clearPreview();
    }
  }

  function paintPreview(projection) {
    clearPreview();
    const target = targets.querySelector(`[data-node-id="${CSS.escape(projection.nodeId)}"]`);
    const item = nodeItems.find((candidate) => candidate.identity.element.id === projection.nodeId);
    if (target === null || item === undefined) return;
    previewGhost = target.cloneNode(true);
    previewGhost.disabled = true;
    previewGhost.removeAttribute("aria-label");
    previewGhost.removeAttribute("aria-pressed");
    previewGhost.setAttribute("aria-hidden", "true");
    previewGhost.classList.add("product-v2-node-ghost");
    positionBox(previewGhost, { center: projection.centre, size: item.hitTarget.size });
    previewGhost.dataset.previewX = projection.centre.x.exact;
    previewGhost.dataset.previewY = projection.centre.y.exact;
    previewGhost.dataset.previewFreeDrag = String(projection.freeDrag);
    targets.append(previewGhost);
    renderGuides(projection.guides);
  }

  function clearPreview() {
    previewGhost?.remove();
    previewGhost = null;
    renderGuides([]);
  }

  function renderGuides(guides) {
    guideLayer.replaceChildren();
    for (const guide of guides) {
      const line = ownerDocument.createElementNS(svgNamespace, "line");
      line.classList.add("product-v2-guide", `product-v2-guide-${guide.kind}`);
      line.dataset.guideKind = guide.kind;
      line.setAttribute("x1", paintNumber(guide.start.x.number));
      line.setAttribute("y1", paintNumber(guide.start.y.number));
      line.setAttribute("x2", paintNumber(guide.end.x.number));
      line.setAttribute("y2", paintNumber(guide.end.y.number));
      line.setAttribute("vector-effect", "non-scaling-stroke");
      guideLayer.append(line);
    }
    const kinds = [...new Set(guides.map((guide) => guide.kind))];
    guideStatus.textContent = guides.length === 0
      ? ""
      : `${guides.length} snap ${guides.length === 1 ? "guide" : "guides"}: ${kinds.join(", ")}`;
  }

  function updateWorkspace(workspace) {
    selection = workspace.selection;
    renderSelection();
    if (workspace.preview === null) clearPreview();
    else paintPreview(workspace.preview);
    const displayed = workspace.displayedRender;
    const writable = workspace.authority === "writable" && displayed !== null && sameFence(correlated.fence, displayed.fence);
    root.dataset.lease = writable ? "writable" : "inert";
    root.setAttribute("aria-disabled", String(!writable));
    if (writable) root.removeAttribute("inert");
    else root.setAttribute("inert", "");
    for (const target of targets.querySelectorAll("button:not(.product-v2-node-ghost)")) {
      target.disabled = !writable;
    }
  }

  function renderSelection() {
    selectionLayer.replaceChildren();
    for (const target of targets.querySelectorAll(".product-v2-node-target:not(.product-v2-node-ghost)")) {
      target.setAttribute("aria-pressed", String(target.dataset.nodeId === selection));
    }
    const selected = nodeItems.find((item) => item.identity.element.id === selection);
    if (selected === undefined) return;
    const rectangle = ownerDocument.createElementNS(svgNamespace, "rect");
    rectangle.classList.add("product-v2-selection");
    setRectangleGeometry(rectangle, selected.box);
    rectangle.setAttribute("vector-effect", "non-scaling-stroke");
    selectionLayer.append(rectangle);
    const left = selected.box.center.x.number - selected.box.size.width.number / 2;
    const right = selected.box.center.x.number + selected.box.size.width.number / 2;
    const bottom = selected.box.center.y.number - selected.box.size.height.number / 2;
    const top = selected.box.center.y.number + selected.box.size.height.number / 2;
    for (const [x, y] of [[left, bottom], [left, top], [right, bottom], [right, top]]) {
      const handle = ownerDocument.createElementNS(svgNamespace, "circle");
      handle.classList.add("product-v2-selection-handle");
      handle.setAttribute("cx", paintNumber(x));
      handle.setAttribute("cy", paintNumber(y));
      handle.setAttribute("r", "0.08");
      handle.setAttribute("vector-effect", "non-scaling-stroke");
      selectionLayer.append(handle);
    }
  }

  function deactivate() {
    deactivated = true;
    if (animationFrame !== null) ownerDocument.defaultView!.cancelAnimationFrame(animationFrame);
    animationFrame = null;
    pendingMoves.clear();
    for (const pointerId of trackedPointerIds as Set<number>) {
      pointerTransport.cancel(pointerId, { type: "lost_capture", pointerId });
      const target = pointerTargets.get(pointerId);
      if (target !== undefined && target.hasPointerCapture(pointerId)) {
        suppressedLostCapture.add(pointerId);
        target.releasePointerCapture(pointerId);
      }
    }
    pointerTargets.clear();
    trackedPointerIds.clear();
    clearPreview();
    root.dataset.lease = "inert";
    root.setAttribute("aria-disabled", "true");
    root.setAttribute("inert", "");
  }

  return Object.freeze({
    element: root,
    fence: correlated.fence,
    executeAction,
    updateWorkspace,
    deactivate,
    thumbnail() {
      const copy = root.cloneNode(true);
      copy.removeAttribute("inert");
      copy.setAttribute("aria-disabled", "true");
      for (const target of copy.querySelectorAll("button")) target.disabled = true;
      return copy;
    },
  });
}

function createTarget(ownerDocument, item) {
  const identity = item.identity.element.id;
  const target = ownerDocument.createElement("button");
  target.type = "button";
  target.className = "product-v2-node-target";
  target.dataset.nodeId = identity;
  target.setAttribute("aria-label", `Source-backed node ${identity}`);
  target.setAttribute("aria-pressed", "false");
  target.disabled = true;
  target.draggable = false;
  positionHitTarget(target, item.hitTarget);
  return target;
}

/** Paint a validated static plan. It is always inert and owns no navigation or edit policy. */
export function createProductV2StaticSurface(plan, ownerDocument = document) {
  const surface = createProductV2RenderSurface({
    fence: {
      session: 0,
      revision: plan.revision,
      ticket: plan.ticket,
      surface: plan.surface,
    },
    plan,
  }, {
    ownerDocument,
    selection: null,
    onPointerEvent() {},
    onNodeActivation() {},
  });
  surface.element.classList.add("static-surface");
  surface.element.setAttribute("aria-hidden", "true");
  return surface.element;
}

function createRectangle(ownerDocument, item) {
  const rectangle = ownerDocument.createElementNS(svgNamespace, "rect");
  rectangle.classList.add("product-v2-rectangle");
  rectangle.dataset.nodeId = item.identity.element.id;
  setRectangleGeometry(rectangle, item.box);
  rectangle.setAttribute("vector-effect", "non-scaling-stroke");
  return rectangle;
}

function createLine(ownerDocument, item) {
  const line = ownerDocument.createElementNS(svgNamespace, "line");
  line.classList.add("product-v2-connector");
  line.dataset.connectorId = item.identity.element.id;
  line.setAttribute("x1", paintNumber(item.start.x.number));
  line.setAttribute("y1", paintNumber(item.start.y.number));
  line.setAttribute("x2", paintNumber(item.end.x.number));
  line.setAttribute("y2", paintNumber(item.end.y.number));
  line.setAttribute("vector-effect", "non-scaling-stroke");
  return line;
}

function createIdentityLabel(ownerDocument, item) {
  const label = ownerDocument.createElement("span");
  label.className = "product-v2-source-identity";
  label.dataset.nodeId = item.identity.element.id;
  label.textContent = item.identity.element.id;
  const leftPercent = (item.box.center.x.number / slideWidth) * 100;
  const nodeTopPercent = (1 - (item.box.center.y.number + item.box.size.height.number / 2) / slideHeight) * 100;
  label.style.left = `clamp(2.5rem, ${leftPercent}%, calc(100% - 2.5rem))`;
  label.style.top = `clamp(0.5rem, calc(${nodeTopPercent}% - 1.75rem), calc(100% - 2rem))`;
  label.setAttribute("aria-hidden", "true");
  return label;
}

function setRectangleGeometry(element, box) {
  element.setAttribute("x", paintNumber(box.center.x.number - box.size.width.number / 2));
  element.setAttribute("y", paintNumber(box.center.y.number - box.size.height.number / 2));
  element.setAttribute("width", paintNumber(box.size.width.number));
  element.setAttribute("height", paintNumber(box.size.height.number));
}

function positionBox(element, box) {
  element.style.left = `${((box.center.x.number - box.size.width.number / 2) / slideWidth) * 100}%`;
  element.style.bottom = `${((box.center.y.number - box.size.height.number / 2) / slideHeight) * 100}%`;
  element.style.width = `${(box.size.width.number / slideWidth) * 100}%`;
  element.style.height = `${(box.size.height.number / slideHeight) * 100}%`;
}

function svg(ownerDocument, className) {
  const element = ownerDocument.createElementNS(svgNamespace, "svg");
  element.classList.add(className);
  element.setAttribute("viewBox", "0 0 16 9");
  element.setAttribute("preserveAspectRatio", "none");
  element.setAttribute("focusable", "false");
  return element;
}

function positionHitTarget(element, box) {
  const width = Math.min(box.size.width.number, slideWidth);
  const height = Math.min(box.size.height.number, slideHeight);
  const left = Math.min(Math.max(box.center.x.number - width / 2, 0), slideWidth - width);
  const bottom = Math.min(Math.max(box.center.y.number - height / 2, 0), slideHeight - height);
  element.style.left = `${(left / slideWidth) * 100}%`;
  element.style.bottom = `${(bottom / slideHeight) * 100}%`;
  element.style.width = `${(width / slideWidth) * 100}%`;
  element.style.height = `${(height / slideHeight) * 100}%`;
}

function paintNumber(value) {
  if (!Number.isFinite(value)) throw new TypeError("validated projection became non-finite during paint");
  if (Object.is(value, -0) || value === 0) return "0";
  return value.toFixed(9).replace(/(?:\.0+|(\.\d+?)0+)$/, "$1");
}

function decimalFact(value) {
  if (!Number.isFinite(value)) throw new TypeError("DOM pointer coordinate is not finite");
  if (Object.is(value, -0) || value === 0) return "0";
  return value.toFixed(6).replace(/(?:\.0+|(\.\d+?)0+)$/, "$1");
}

function domButtonFact(event) {
  if (Number.isSafeInteger(event.button) && event.button >= 0) return event.button;
  // Pointer move uses -1 for “no button transition”; the frozen schema carries
  // the simultaneously reported pressed button as a non-negative browser fact.
  if ((event.buttons & 1) !== 0) return 0;
  if ((event.buttons & 4) !== 0) return 1;
  if ((event.buttons & 2) !== 0) return 2;
  return 0;
}

function snapshotBounds(value) {
  const bounds = {
    left: value?.left, right: value?.right, top: value?.top, bottom: value?.bottom,
    width: value?.width, height: value?.height,
  };
  if (!Object.values(bounds).every(Number.isFinite) || bounds.width <= 0 || bounds.height <= 0 || bounds.right < bounds.left || bounds.bottom < bounds.top) return null;
  return Object.freeze(bounds);
}

function sameFence(left, right) {
  return left.session === right.session && left.revision === right.revision && left.ticket === right.ticket && left.surface.frame === right.surface.frame && left.surface.kind === right.surface.kind;
}
