import { requireValidatedRenderPlan } from "./engine-v1.js";

const svgNamespace = "http://www.w3.org/2000/svg";
const slideWidth = 16;
const slideHeight = 9;
const pointerPrecision = 6;

/**
 * Translate one validated renderer-neutral plan into a detached DOM/SVG
 * surface. The returned controller starts inert. Its caller owns the source
 * lease and may activate it only after the plan is current and live.
 *
 * @param {Readonly<Record<string, unknown>>} plan
 * @param {{onMoveIntent: (intent: {
 *   revision: number,
 *   nodeId: string,
 *   destination: {x: string, y: string}
 * }) => void, ownerDocument?: Document}} options
 * @returns {{
 *   element: HTMLElement,
 *   revision: number,
 *   activate: () => void,
 *   deactivate: () => void,
 *   cancelGesture: () => void
 * }}
 */
export function createTikzRenderSurface(plan, options) {
  requireValidatedRenderPlan(plan);
  if (typeof options?.onMoveIntent !== "function") {
    throw new TypeError("TikZ renderer requires an onMoveIntent callback");
  }

  const ownerDocument = options.ownerDocument ?? document;
  const surface = ownerDocument.createElement("div");
  surface.className = "slice1-render-surface";
  surface.dataset.sourceRevision = String(plan.sourceRevision);
  surface.dataset.coordinateSpace = plan.coordinateSpace;
  surface.dataset.lease = "inert";
  surface.setAttribute("aria-disabled", "true");
  surface.setAttribute("inert", "");

  const geometry = ownerDocument.createElementNS(svgNamespace, "svg");
  geometry.classList.add("slice1-geometry");
  geometry.setAttribute("viewBox", "0 0 16 9");
  geometry.setAttribute("preserveAspectRatio", "none");
  geometry.setAttribute("aria-hidden", "true");
  geometry.setAttribute("focusable", "false");

  const yUpGroup = ownerDocument.createElementNS(svgNamespace, "g");
  yUpGroup.setAttribute("transform", "translate(0 9) scale(1 -1)");
  const connector = ownerDocument.createElementNS(svgNamespace, "line");
  connector.dataset.kind = plan.connector.kind;
  connector.dataset.startX = plan.connector.start.x;
  connector.dataset.startY = plan.connector.start.y;
  connector.dataset.endX = plan.connector.end.x;
  connector.dataset.endY = plan.connector.end.y;
  connector.setAttribute("x1", plan.connector.start.x);
  connector.setAttribute("y1", plan.connector.start.y);
  connector.setAttribute("x2", plan.connector.end.x);
  connector.setAttribute("y2", plan.connector.end.y);
  connector.setAttribute("vector-effect", "non-scaling-stroke");
  yUpGroup.append(connector);
  geometry.append(yUpGroup);

  const contentLayer = ownerDocument.createElement("div");
  contentLayer.className = "slice1-content";
  const node = ownerDocument.createElement("button");
  node.type = "button";
  node.className = "slice1-content-node";
  node.dataset.nodeId = plan.node.id;
  node.dataset.planX = plan.node.center.x;
  node.dataset.planY = plan.node.center.y;
  node.setAttribute("aria-label", `Move node ${plan.node.id}`);
  renderNodeContent(node, plan.node, ownerDocument);
  positionHtmlNode(node, plan.node.center);
  node.disabled = true;
  contentLayer.append(node);

  surface.append(geometry, contentLayer);

  let interactive = false;
  let gesture = null;

  node.addEventListener("pointerdown", (event) => {
    if (
      !interactive ||
      !event.isPrimary ||
      event.button !== 0 ||
      gesture !== null
    ) {
      return;
    }

    const bounds = surface.getBoundingClientRect();
    if (
      !Number.isFinite(bounds.left) ||
      !Number.isFinite(bounds.top) ||
      !Number.isFinite(bounds.width) ||
      !Number.isFinite(bounds.height) ||
      bounds.width <= 0 ||
      bounds.height <= 0
    ) {
      return;
    }

    const ghost = node.cloneNode(true);
    ghost.removeAttribute("id");
    ghost.removeAttribute("aria-label");
    ghost.disabled = true;
    ghost.classList.add("slice1-drag-ghost");
    ghost.setAttribute("aria-hidden", "true");
    contentLayer.append(ghost);

    gesture = {
      pointerId: event.pointerId,
      bounds: {
        left: bounds.left,
        right: bounds.right,
        top: bounds.top,
        bottom: bounds.bottom,
        width: bounds.width,
        height: bounds.height,
      },
      ghost,
    };
    node.dataset.dragging = "true";
    try {
      node.setPointerCapture(event.pointerId);
    } catch {
      // Synthetic conformance events have no browser-owned active pointer.
      // Real pointer interaction still uses capture; explicit events on this
      // node remain usable for deterministic adapter tests.
    }
    positionGhost(event.clientX, event.clientY);
    event.preventDefault();
  });

  node.addEventListener("pointermove", (event) => {
    if (gesture?.pointerId !== event.pointerId) {
      return;
    }
    positionGhost(event.clientX, event.clientY);
  });

  node.addEventListener("pointerup", (event) => {
    if (gesture?.pointerId !== event.pointerId) {
      return;
    }
    const completedGesture = gesture;
    const destination = pointFromPointer(
      event.clientX,
      event.clientY,
      completedGesture.bounds,
    );
    clearGesture();
    if (destination === null || !interactive) {
      return;
    }
    options.onMoveIntent(
      Object.freeze({
        revision: plan.sourceRevision,
        nodeId: plan.node.id,
        destination: Object.freeze(destination),
      }),
    );
  });

  node.addEventListener("pointercancel", clearGesture);
  node.addEventListener("lostpointercapture", () => {
    if (gesture !== null && !node.hasPointerCapture(gesture.pointerId)) {
      clearGesture();
    }
  });

  function positionGhost(clientX, clientY) {
    if (gesture === null) {
      return;
    }
    const relativeX =
      ((clientX - gesture.bounds.left) / gesture.bounds.width) * 100;
    const relativeY =
      ((clientY - gesture.bounds.top) / gesture.bounds.height) * 100;
    if (!Number.isFinite(relativeX) || !Number.isFinite(relativeY)) {
      return;
    }
    gesture.ghost.style.left = `${relativeX}%`;
    gesture.ghost.style.top = `${relativeY}%`;
  }

  function clearGesture() {
    if (gesture === null) {
      return;
    }
    const pointerId = gesture.pointerId;
    gesture.ghost.remove();
    gesture = null;
    delete node.dataset.dragging;
    if (node.hasPointerCapture(pointerId)) {
      node.releasePointerCapture(pointerId);
    }
  }

  function activate() {
    interactive = true;
    surface.removeAttribute("inert");
    surface.setAttribute("aria-disabled", "false");
    surface.dataset.lease = "active";
    node.disabled = false;
  }

  function deactivate() {
    interactive = false;
    clearGesture();
    node.disabled = true;
    surface.setAttribute("inert", "");
    surface.setAttribute("aria-disabled", "true");
    surface.dataset.lease = "inert";
  }

  return Object.freeze({
    element: surface,
    revision: plan.sourceRevision,
    activate,
    deactivate,
    cancelGesture: clearGesture,
  });
}

/**
 * Draw a node's content from the engine's resolved runs.
 *
 * Every styling decision has already been made in Haskell: which construct
 * applies where, and what `red!50` resolves to in sRGB. The host's job is to
 * apply them, not to interpret markup. Nothing here parses LaTeX, Markdown, or
 * HTML, and nothing here uses innerHTML, so authored source can never become
 * markup in this document.
 *
 * Each run keeps the tree path it came from in a data attribute. That is what a
 * later click-to-edit gesture resolves back into an edit on the authored tree.
 *
 * @param {HTMLElement} node
 * @param {Readonly<Record<string, unknown>>} planNode
 * @param {Document} ownerDocument
 */
function renderNodeContent(node, planNode, ownerDocument) {
  node.replaceChildren();
  node.dataset.contentStatus = planNode.contentStatus.kind;
  if (planNode.contentStatus.kind === "opaque") {
    node.dataset.contentReason = planNode.contentStatus.reason;
  } else {
    delete node.dataset.contentReason;
  }

  for (const run of planNode.runs) {
    if (run.kind === "break") {
      node.append(ownerDocument.createElement("br"));
      continue;
    }
    // createTextNode, never innerHTML: the run's text is content, not markup.
    const span = ownerDocument.createElement("span");
    span.className = `slice1-run slice1-run-${run.kind}`;
    span.dataset.runPath = run.path.join(".");
    if (run.dialect !== null) {
      span.dataset.dialect = run.dialect.name;
    }
    applyRunStyle(span, run.style);
    span.append(ownerDocument.createTextNode(run.text));
    node.append(span);
  }
}

/**
 * Apply one run's resolved styling.
 *
 * A property the author never stated is left unset rather than given a default,
 * so the stylesheet and theme keep their say.
 *
 * @param {HTMLElement} element
 * @param {Readonly<Record<string, unknown>>} style
 */
function applyRunStyle(element, style) {
  if (style.weight === "bold") {
    element.style.fontWeight = "700";
  }
  if (style.slant === "italic") {
    element.style.fontStyle = "italic";
  }
  if (style.family === "sans") {
    element.style.fontFamily = "var(--slice1-font-sans, sans-serif)";
  } else if (style.family === "mono") {
    element.style.fontFamily = "var(--slice1-font-mono, monospace)";
  }
  if (style.variant === "smallcaps") {
    element.style.fontVariantCaps = "small-caps";
  }
  const decorations = [];
  if (style.underline) {
    decorations.push("underline");
  }
  if (style.strike) {
    decorations.push("line-through");
  }
  if (decorations.length > 0) {
    element.style.textDecorationLine = decorations.join(" ");
  }
  if (style.highlight) {
    element.classList.add("slice1-run-highlight");
  }
  if (style.foreground !== null) {
    element.style.color = style.foreground.srgb;
  }
  if (style.background !== null) {
    element.style.backgroundColor = style.background.srgb;
  }
}

function positionHtmlNode(node, point) {
  const x = Number(point.x);
  const y = Number(point.y);
  const left = (x / slideWidth) * 100;
  const top = ((slideHeight - y) / slideHeight) * 100;
  if (!Number.isFinite(left) || !Number.isFinite(top)) {
    throw new TypeError("Render-plan coordinate is not finite for the DOM");
  }
  node.style.left = `${left}%`;
  node.style.top = `${top}%`;
}

function pointFromPointer(clientX, clientY, bounds) {
  if (
    !Number.isFinite(clientX) ||
    !Number.isFinite(clientY) ||
    clientX < bounds.left ||
    clientX > bounds.right ||
    clientY < bounds.top ||
    clientY > bounds.bottom
  ) {
    return null;
  }
  const x = ((clientX - bounds.left) / bounds.width) * slideWidth;
  const y =
    slideHeight -
    ((clientY - bounds.top) / bounds.height) * slideHeight;
  if (!Number.isFinite(x) || !Number.isFinite(y)) {
    return null;
  }
  return {
    x: canonicalPointerDecimal(x),
    y: canonicalPointerDecimal(y),
  };
}

function canonicalPointerDecimal(value) {
  const rounded = Math.round(value * 10 ** pointerPrecision) / 10 ** pointerPrecision;
  if (Object.is(rounded, -0) || rounded === 0) {
    return "0";
  }
  return rounded.toFixed(pointerPrecision).replace(/(?:\.0+|(\.\d+?)0+)$/, "$1");
}
