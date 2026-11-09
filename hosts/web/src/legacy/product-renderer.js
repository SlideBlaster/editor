/**
 * Disposable browser projection of the shared Haskell product model.
 *
 * The host receives direct, resolved geometry in the 16 × 9 y-up slide space.
 * It does not resolve themes, catalog rows, stencil identifiers, layout, or
 * snapping. Pointer gestures emit revision-fenced semantic intents and wait
 * for a successor projection before changing authoritative state.
 */

const svgNamespace = "http://www.w3.org/2000/svg";
const slideWidth = 16;
const slideHeight = 9;
const pointerPrecision = 6;
const geometryPrecision = 9;
const dragThresholdPixels = 4;
const maximumNodes = 10_000;
const maximumGuides = 4_096;
const maximumOutlines = 2_048;
const maximumPathSegments = 16_384;
const maximumTextLength = 16_384;

const identifierPattern = /^[A-Za-z_][A-Za-z0-9_.-]*$/;
const decimalPattern = /^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?$/;
const lineJoins = new Set(["miter", "round", "bevel"]);
const guideKinds = new Set(["point", "alignment", "spacing", "binding"]);

/**
 * A Haskell-to-browser product projection violated its closed wire contract.
 */
export class ProductProjectionError extends Error {
  constructor(message) {
    super(message);
    this.name = "ProductProjectionError";
  }
}

/**
 * Validate and defensively copy a product workspace projection.
 *
 * Box `x`/`y` values are centres in the y-up slide coordinate system.
 *
 * @param {unknown} value
 * @returns {Readonly<Record<string, unknown>>}
 */
export function validateProductWorkspace(value) {
  const root = expectRecord(value, "workspace");
  requireExactKeys(
    root,
    [
      "revision",
      "persistent",
      "theme",
      "selectedNodeId",
      "guides",
      "nodes",
    ],
    "workspace",
  );

  const revision = expectRevision(root.revision, "workspace.revision");
  const persistent = expectBoolean(root.persistent, "workspace.persistent");
  const theme = validateTheme(root.theme, "workspace.theme");
  const guides = expectArray(root.guides, "workspace.guides", maximumGuides).map(
    (guide, index) => validateGuide(guide, `workspace.guides[${index}]`),
  );
  const nodes = expectArray(root.nodes, "workspace.nodes", maximumNodes).map(
    (node, index) => validateNode(node, `workspace.nodes[${index}]`),
  );

  const nodeIds = new Set();
  for (const node of nodes) {
    if (nodeIds.has(node.id)) {
      throw new ProductProjectionError(
        `workspace.nodes contains duplicate node id ${node.id}`,
      );
    }
    nodeIds.add(node.id);
  }

  const selectedNodeId =
    root.selectedNodeId === null
      ? null
      : expectIdentifier(root.selectedNodeId, "workspace.selectedNodeId");
  if (selectedNodeId !== null && !nodeIds.has(selectedNodeId)) {
    throw new ProductProjectionError(
      "workspace.selectedNodeId does not identify a projected node",
    );
  }

  return deepFreeze({
    revision,
    persistent,
    theme,
    selectedNodeId,
    guides,
    nodes,
  });
}

/**
 * Validate one already-resolved outline collection and its direct paint.
 * Shape-palette previews use this exact function rather than owning another
 * geometry vocabulary.
 *
 * @param {unknown} outlines
 * @param {unknown} style
 * @param {string} [path]
 */
export function validateResolvedOutlineSet(
  outlines,
  style,
  path = "resolvedOutlineSet",
) {
  const validatedOutlines = expectArray(
    outlines,
    `${path}.outlines`,
    maximumOutlines,
  ).map((outline, index) =>
    validateOutline(outline, `${path}.outlines[${index}]`),
  );
  return deepFreeze({
    outlines: validatedOutlines,
    style: validateShapeStyle(style, `${path}.style`),
  });
}

/**
 * Convert a client pointer to the fixed 16 × 9 y-up slide coordinate space.
 * Out-of-bounds or unusable rectangles return null.
 *
 * @param {number} clientX
 * @param {number} clientY
 * @param {{left:number,right:number,top:number,bottom:number,width:number,height:number}} bounds
 * @returns {{x:string,y:string}|null}
 */
export function clientPointToSlide(clientX, clientY, bounds) {
  if (
    !Number.isFinite(clientX) ||
    !Number.isFinite(clientY) ||
    !isUsableBounds(bounds) ||
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
  return Object.freeze({
    x: canonicalDecimal(x, pointerPrecision),
    y: canonicalDecimal(y, pointerPrecision),
  });
}

/**
 * Build the exact SVG `d` value for one validated direct path outline.
 * Arc rotation and sweep are reflected because the enclosing SVG group maps
 * the y-up slide plane into SVG's y-down viewport.
 *
 * @param {unknown} value
 * @returns {string}
 */
export function pathDataFromProjection(value) {
  const outline = validatePathOutline(value, "path");
  const commands = [
    `M ${svgPoint(outline.start)}`,
    ...outline.segments.map(pathSegmentCommand),
  ];
  if (outline.closed) {
    commands.push("Z");
  }
  return commands.join(" ");
}

/**
 * @param {number} revision
 * @param {string} nodeId
 */
export function createSelectNodeIntent(revision, nodeId) {
  return deepFreeze({
    type: "select_node",
    revision: expectRevision(revision, "select_node.revision"),
    nodeId: expectIdentifier(nodeId, "select_node.nodeId"),
  });
}

/**
 * @param {number} revision
 * @param {string} nodeId
 * @param {{x:string,y:string}} point
 * @param {"snap"|"free"} mode
 */
export function createMoveNodeIntent(revision, nodeId, point, mode) {
  return deepFreeze({
    type: "move_node",
    revision: expectRevision(revision, "move_node.revision"),
    nodeId: expectIdentifier(nodeId, "move_node.nodeId"),
    point: validateIntentPoint(point, "move_node.point"),
    mode: expectOneOf(mode, ["snap", "free"], "move_node.mode"),
  });
}

/**
 * @param {number} revision
 * @param {string} shapeId
 * @param {{x:string,y:string}} point
 */
export function createInsertShapeIntent(revision, shapeId, point) {
  return deepFreeze({
    type: "insert_shape",
    revision: expectRevision(revision, "insert_shape.revision"),
    shapeId: expectIdentifier(shapeId, "insert_shape.shapeId"),
    point: validateIntentPoint(point, "insert_shape.point"),
  });
}

/**
 * Create one SVG group from direct resolved outlines.
 *
 * @param {Document} ownerDocument
 * @param {unknown} outlines
 * @param {unknown} style
 * @returns {SVGGElement}
 */
export function createResolvedOutlineGroup(ownerDocument, outlines, style) {
  if (
    ownerDocument === null ||
    typeof ownerDocument !== "object" ||
    typeof ownerDocument.createElementNS !== "function"
  ) {
    throw new TypeError("Resolved outlines require an owner document");
  }
  const validated = validateResolvedOutlineSet(outlines, style);
  const group = ownerDocument.createElementNS(svgNamespace, "g");
  for (const outline of validated.outlines) {
    const element = createOutlineElement(ownerDocument, outline);
    applyShapeStyle(element, validated.style);
    group.append(element);
  }
  return group;
}

/**
 * Mount one layered product canvas.
 *
 * @param {HTMLElement} container
 * @param {{
 *   workspace: unknown,
 *   onIntent: (intent: Readonly<Record<string, unknown>>) => unknown
 * }} options
 * @returns {{
 *   element: HTMLElement,
 *   revision: () => number,
 *   update: (workspace: unknown) => void,
 *   cancelGesture: () => void,
 *   destroy: () => void
 * }}
 */
export function mountProductRenderer(container, options) {
  requireContainer(container, "Product renderer");
  if (typeof options?.onIntent !== "function") {
    throw new TypeError("Product renderer requires an onIntent callback");
  }

  const ownerDocument = container.ownerDocument;
  const root = ownerDocument.createElement("section");
  root.className = "sb-product-renderer";
  root.setAttribute("role", "application");
  root.setAttribute("aria-label", "Slide canvas");
  root.style.cssText =
    "position:relative;box-sizing:border-box;width:100%;aspect-ratio:16/9;" +
    "overflow:hidden;isolation:isolate;touch-action:none;user-select:none";
  container.append(root);

  let workspace = validateProductWorkspace(options.workspace);
  let gesture = null;
  let destroyed = false;
  render();

  function render() {
    cancelGesture();
    root.replaceChildren();
    root.dataset.revision = String(workspace.revision);
    root.dataset.persistent = String(workspace.persistent);
    root.style.background = workspace.theme.background;
    root.style.color = workspace.theme.foreground;

    const geometry = createSvgLayer(ownerDocument, "sb-product-geometry");
    geometry.setAttribute("aria-hidden", "true");
    const geometryYUp = ownerDocument.createElementNS(svgNamespace, "g");
    geometryYUp.setAttribute("transform", "translate(0 9) scale(1 -1)");
    for (const node of workspace.nodes) {
      const group = createResolvedOutlineGroup(
        ownerDocument,
        node.outlines,
        node.style,
      );
      group.dataset.nodeId = node.id;
      geometryYUp.append(group);
    }
    geometry.append(geometryYUp);

    const content = ownerDocument.createElement("div");
    content.className = "sb-product-content";
    content.style.cssText =
      "position:absolute;inset:0;z-index:2;pointer-events:none";
    for (const node of workspace.nodes) {
      content.append(createNodeHitTarget(node));
    }

    const overlay = createSvgLayer(ownerDocument, "sb-product-overlay");
    overlay.style.zIndex = "3";
    overlay.setAttribute("aria-hidden", "true");
    overlay.setAttribute("pointer-events", "none");
    const overlayYUp = ownerDocument.createElementNS(svgNamespace, "g");
    overlayYUp.setAttribute("transform", "translate(0 9) scale(1 -1)");
    appendGuides(overlayYUp);
    appendSelection(overlayYUp);
    overlay.append(overlayYUp);

    root.append(geometry, content, overlay);
  }

  function createNodeHitTarget(node) {
    const target = ownerDocument.createElement("button");
    target.type = "button";
    target.className = "sb-product-node";
    target.dataset.nodeId = node.id;
    target.setAttribute("aria-label", node.label);
    target.setAttribute(
      "aria-pressed",
      String(workspace.selectedNodeId === node.id),
    );
    target.textContent = node.label;
    target.style.cssText =
      "position:absolute;box-sizing:border-box;border:0;background:transparent;" +
      "padding:.08rem;overflow:hidden;display:flex;align-items:center;" +
      "justify-content:center;text-align:center;font:500 clamp(.5rem,1.35vw,.95rem)" +
      "/1.15 system-ui,sans-serif;color:inherit;cursor:grab;pointer-events:auto;" +
      "touch-action:none";
    positionHtmlBox(target, node.box);

    target.addEventListener("pointerdown", (event) => {
      if (
        destroyed ||
        gesture !== null ||
        !event.isPrimary ||
        event.button !== 0
      ) {
        return;
      }
      const bounds = snapshotBounds(root.getBoundingClientRect());
      if (bounds === null) {
        return;
      }
      const startPoint = clientPointToSlide(
        event.clientX,
        event.clientY,
        bounds,
      );
      if (startPoint === null) {
        return;
      }

      const ghost = target.cloneNode(true);
      ghost.disabled = true;
      ghost.removeAttribute("aria-label");
      ghost.removeAttribute("aria-pressed");
      ghost.setAttribute("aria-hidden", "true");
      ghost.classList.add("sb-product-node-ghost");
      ghost.style.opacity = "0.58";
      ghost.style.pointerEvents = "none";
      content.append(ghost);

      gesture = {
        pointerId: event.pointerId,
        node,
        target,
        ghost,
        bounds,
        startClientX: event.clientX,
        startClientY: event.clientY,
        dragged: false,
        free: Boolean(event.altKey),
      };
      target.dataset.dragging = "true";
      try {
        target.setPointerCapture(event.pointerId);
      } catch {
        // Synthetic DOM tests may not have a browser-owned active pointer.
      }
      event.preventDefault();
    });

    target.addEventListener("pointermove", (event) => {
      if (gesture?.pointerId !== event.pointerId) {
        return;
      }
      gesture.free ||= Boolean(event.altKey);
      if (
        !gesture.dragged &&
        pointerDistance(
          gesture.startClientX,
          gesture.startClientY,
          event.clientX,
          event.clientY,
        ) >= dragThresholdPixels
      ) {
        gesture.dragged = true;
        gesture.target.style.cursor = "grabbing";
      }
      if (!gesture.dragged) {
        return;
      }
      const point = clientPointToSlide(
        event.clientX,
        event.clientY,
        gesture.bounds,
      );
      if (point !== null) {
        positionHtmlBox(gesture.ghost, {
          x: Number(point.x),
          y: Number(point.y),
          width: gesture.node.box.width,
          height: gesture.node.box.height,
        });
      }
      event.preventDefault();
    });

    target.addEventListener("pointerup", (event) => {
      if (gesture?.pointerId !== event.pointerId) {
        return;
      }
      const completed = gesture;
      completed.free ||= Boolean(event.altKey);
      const point = clientPointToSlide(
        event.clientX,
        event.clientY,
        completed.bounds,
      );
      cancelGesture();
      if (destroyed || point === null) {
        return;
      }
      if (completed.dragged) {
        options.onIntent(
          createMoveNodeIntent(
            workspace.revision,
            completed.node.id,
            point,
            completed.free ? "free" : "snap",
          ),
        );
      } else {
        options.onIntent(
          createSelectNodeIntent(workspace.revision, completed.node.id),
        );
      }
    });

    target.addEventListener("pointercancel", cancelGesture);
    target.addEventListener("lostpointercapture", () => {
      if (
        gesture !== null &&
        gesture.target === target &&
        !target.hasPointerCapture(gesture.pointerId)
      ) {
        cancelGesture();
      }
    });
    target.addEventListener("click", (event) => {
      if (!destroyed && event.detail === 0) {
        options.onIntent(createSelectNodeIntent(workspace.revision, node.id));
      }
    });
    return target;
  }

  function appendGuides(parent) {
    for (const guide of workspace.guides) {
      const line = ownerDocument.createElementNS(svgNamespace, "line");
      line.classList.add("sb-product-guide");
      line.dataset.kind = guide.kind;
      line.setAttribute("x1", svgNumber(guide.start.x));
      line.setAttribute("y1", svgNumber(guide.start.y));
      line.setAttribute("x2", svgNumber(guide.end.x));
      line.setAttribute("y2", svgNumber(guide.end.y));
      line.setAttribute("fill", "none");
      line.setAttribute("stroke", workspace.theme.guide);
      line.setAttribute("stroke-width", "0.025");
      line.setAttribute("stroke-dasharray", guide.kind === "point" ? "0.04 0.04" : "0.1 0.06");
      line.setAttribute("vector-effect", "non-scaling-stroke");
      parent.append(line);
    }
  }

  function appendSelection(parent) {
    if (workspace.selectedNodeId === null) {
      return;
    }
    const node = workspace.nodes.find(
      (candidate) => candidate.id === workspace.selectedNodeId,
    );
    if (node === undefined) {
      return;
    }
    const left = node.box.x - node.box.width / 2;
    const bottom = node.box.y - node.box.height / 2;
    const selection = ownerDocument.createElementNS(svgNamespace, "rect");
    selection.classList.add("sb-product-selection");
    selection.setAttribute("x", svgNumber(left));
    selection.setAttribute("y", svgNumber(bottom));
    selection.setAttribute("width", svgNumber(node.box.width));
    selection.setAttribute("height", svgNumber(node.box.height));
    selection.setAttribute("fill", "none");
    selection.setAttribute("stroke", workspace.theme.selection);
    selection.setAttribute("stroke-width", "0.035");
    selection.setAttribute("vector-effect", "non-scaling-stroke");
    parent.append(selection);

    for (const point of handlePoints(node.box)) {
      const handle = ownerDocument.createElementNS(svgNamespace, "circle");
      handle.classList.add("sb-product-selection-handle");
      handle.setAttribute("cx", svgNumber(point.x));
      handle.setAttribute("cy", svgNumber(point.y));
      handle.setAttribute("r", "0.075");
      handle.setAttribute("fill", workspace.theme.background);
      handle.setAttribute("stroke", workspace.theme.selection);
      handle.setAttribute("stroke-width", "0.025");
      handle.setAttribute("vector-effect", "non-scaling-stroke");
      parent.append(handle);
    }
  }

  function cancelGesture() {
    if (gesture === null) {
      return;
    }
    const { target, ghost, pointerId } = gesture;
    gesture = null;
    delete target.dataset.dragging;
    target.style.cursor = "grab";
    ghost.remove();
    if (target.hasPointerCapture(pointerId)) {
      target.releasePointerCapture(pointerId);
    }
  }

  function update(nextWorkspace) {
    if (destroyed) {
      throw new Error("Cannot update a destroyed product renderer");
    }
    workspace = validateProductWorkspace(nextWorkspace);
    render();
  }

  function destroy() {
    if (destroyed) {
      return;
    }
    destroyed = true;
    cancelGesture();
    root.remove();
  }

  return Object.freeze({
    element: root,
    revision: () => workspace.revision,
    update,
    cancelGesture,
    destroy,
  });
}

function validateTheme(value, path) {
  const theme = expectRecord(value, path);
  requireExactKeys(
    theme,
    ["background", "foreground", "selection", "guide"],
    path,
  );
  return {
    background: expectPaint(theme.background, `${path}.background`),
    foreground: expectPaint(theme.foreground, `${path}.foreground`),
    selection: expectPaint(theme.selection, `${path}.selection`),
    guide: expectPaint(theme.guide, `${path}.guide`),
  };
}

function validateNode(value, path) {
  const node = expectRecord(value, path);
  requireExactKeys(
    node,
    ["id", "label", "box", "outlines", "style"],
    path,
  );
  const resolved = validateResolvedOutlineSet(
    node.outlines,
    node.style,
    path,
  );
  return {
    id: expectIdentifier(node.id, `${path}.id`),
    label: expectText(node.label, `${path}.label`),
    box: validateBox(node.box, `${path}.box`),
    outlines: resolved.outlines,
    style: resolved.style,
  };
}

function validateGuide(value, path) {
  const guide = expectRecord(value, path);
  requireExactKeys(guide, ["kind", "start", "end"], path);
  return {
    kind: expectOneOf(guide.kind, guideKinds, `${path}.kind`),
    start: validatePoint(guide.start, `${path}.start`),
    end: validatePoint(guide.end, `${path}.end`),
  };
}

function validateOutline(value, path) {
  const outline = expectRecord(value, path);
  const kind = expectOneOf(
    outline.kind,
    ["rectangle", "ellipse", "polygon", "path"],
    `${path}.kind`,
  );
  switch (kind) {
    case "rectangle": {
      requireAllowedKeys(outline, ["kind", "box", "radius"], path);
      const radius =
        outline.radius === undefined
          ? 0
          : expectNonNegativeNumber(outline.radius, `${path}.radius`);
      return {
        kind,
        box: validateBox(outline.box, `${path}.box`),
        radius,
      };
    }
    case "ellipse":
      requireExactKeys(outline, ["kind", "box"], path);
      return {
        kind,
        box: validateBox(outline.box, `${path}.box`),
      };
    case "polygon": {
      requireExactKeys(outline, ["kind", "points"], path);
      const points = expectArray(
        outline.points,
        `${path}.points`,
        maximumPathSegments,
      ).map((point, index) =>
        validatePoint(point, `${path}.points[${index}]`),
      );
      if (points.length < 3) {
        throw new ProductProjectionError(
          `${path}.points must contain at least three points`,
        );
      }
      return { kind, points };
    }
    case "path":
      return validatePathOutline(outline, path);
  }
}

function validatePathOutline(value, path) {
  const outline = expectRecord(value, path);
  requireExactKeys(outline, ["kind", "start", "segments", "closed"], path);
  if (outline.kind !== "path") {
    throw new ProductProjectionError(`${path}.kind must be path`);
  }
  const segments = expectArray(
    outline.segments,
    `${path}.segments`,
    maximumPathSegments,
  ).map((segment, index) =>
    validatePathSegment(segment, `${path}.segments[${index}]`),
  );
  if (segments.length === 0) {
    throw new ProductProjectionError(
      `${path}.segments must contain at least one segment`,
    );
  }
  return {
    kind: "path",
    start: validatePoint(outline.start, `${path}.start`),
    segments,
    closed: expectBoolean(outline.closed, `${path}.closed`),
  };
}

function validatePathSegment(value, path) {
  const segment = expectRecord(value, path);
  const kind = expectOneOf(
    segment.kind,
    ["line", "quadratic", "cubic", "arc"],
    `${path}.kind`,
  );
  switch (kind) {
    case "line":
      requireExactKeys(segment, ["kind", "end"], path);
      return {
        kind,
        end: validatePoint(segment.end, `${path}.end`),
      };
    case "quadratic":
      requireExactKeys(segment, ["kind", "control", "end"], path);
      return {
        kind,
        control: validatePoint(segment.control, `${path}.control`),
        end: validatePoint(segment.end, `${path}.end`),
      };
    case "cubic":
      requireExactKeys(
        segment,
        ["kind", "control1", "control2", "end"],
        path,
      );
      return {
        kind,
        control1: validatePoint(segment.control1, `${path}.control1`),
        control2: validatePoint(segment.control2, `${path}.control2`),
        end: validatePoint(segment.end, `${path}.end`),
      };
    case "arc":
      requireExactKeys(
        segment,
        [
          "kind",
          "radiusX",
          "radiusY",
          "rotation",
          "largeArc",
          "clockwise",
          "end",
        ],
        path,
      );
      return {
        kind,
        radiusX: expectPositiveNumber(segment.radiusX, `${path}.radiusX`),
        radiusY: expectPositiveNumber(segment.radiusY, `${path}.radiusY`),
        rotation: expectFiniteNumber(segment.rotation, `${path}.rotation`),
        largeArc: expectBoolean(segment.largeArc, `${path}.largeArc`),
        clockwise: expectBoolean(segment.clockwise, `${path}.clockwise`),
        end: validatePoint(segment.end, `${path}.end`),
      };
  }
}

function validateShapeStyle(value, path) {
  const style = expectRecord(value, path);
  requireAllowedKeys(
    style,
    ["fill", "stroke", "strokeWidth", "opacity", "dash", "lineJoin"],
    path,
  );
  return {
    fill:
      style.fill === undefined || style.fill === null
        ? "none"
        : expectPaint(style.fill, `${path}.fill`),
    stroke:
      style.stroke === undefined || style.stroke === null
        ? "none"
        : expectPaint(style.stroke, `${path}.stroke`),
    strokeWidth:
      style.strokeWidth === undefined
        ? 0
        : expectNonNegativeNumber(style.strokeWidth, `${path}.strokeWidth`),
    opacity:
      style.opacity === undefined
        ? 1
        : expectUnitInterval(style.opacity, `${path}.opacity`),
    dash:
      style.dash === undefined
        ? []
        : expectArray(style.dash, `${path}.dash`, 128).map(
            (entry, index) =>
              expectNonNegativeNumber(entry, `${path}.dash[${index}]`),
          ),
    lineJoin:
      style.lineJoin === undefined
        ? "miter"
        : expectOneOf(style.lineJoin, lineJoins, `${path}.lineJoin`),
  };
}

function validateBox(value, path) {
  const box = expectRecord(value, path);
  requireExactKeys(box, ["x", "y", "width", "height"], path);
  return {
    x: expectFiniteNumber(box.x, `${path}.x`),
    y: expectFiniteNumber(box.y, `${path}.y`),
    width: expectPositiveNumber(box.width, `${path}.width`),
    height: expectPositiveNumber(box.height, `${path}.height`),
  };
}

function validatePoint(value, path) {
  const point = expectRecord(value, path);
  requireExactKeys(point, ["x", "y"], path);
  return {
    x: expectFiniteNumber(point.x, `${path}.x`),
    y: expectFiniteNumber(point.y, `${path}.y`),
  };
}

function validateIntentPoint(value, path) {
  const point = expectRecord(value, path);
  requireExactKeys(point, ["x", "y"], path);
  return {
    x: expectDecimal(point.x, `${path}.x`),
    y: expectDecimal(point.y, `${path}.y`),
  };
}

function createSvgLayer(ownerDocument, className) {
  const svg = ownerDocument.createElementNS(svgNamespace, "svg");
  svg.classList.add(className);
  svg.setAttribute("viewBox", "0 0 16 9");
  svg.setAttribute("preserveAspectRatio", "none");
  svg.setAttribute("focusable", "false");
  svg.style.cssText =
    "position:absolute;inset:0;width:100%;height:100%;overflow:visible";
  return svg;
}

function createOutlineElement(ownerDocument, outline) {
  switch (outline.kind) {
    case "rectangle": {
      const rectangle = ownerDocument.createElementNS(svgNamespace, "rect");
      rectangle.setAttribute(
        "x",
        svgNumber(outline.box.x - outline.box.width / 2),
      );
      rectangle.setAttribute(
        "y",
        svgNumber(outline.box.y - outline.box.height / 2),
      );
      rectangle.setAttribute("width", svgNumber(outline.box.width));
      rectangle.setAttribute("height", svgNumber(outline.box.height));
      if (outline.radius > 0) {
        rectangle.setAttribute("rx", svgNumber(outline.radius));
        rectangle.setAttribute("ry", svgNumber(outline.radius));
      }
      return rectangle;
    }
    case "ellipse": {
      const ellipse = ownerDocument.createElementNS(svgNamespace, "ellipse");
      ellipse.setAttribute("cx", svgNumber(outline.box.x));
      ellipse.setAttribute("cy", svgNumber(outline.box.y));
      ellipse.setAttribute("rx", svgNumber(outline.box.width / 2));
      ellipse.setAttribute("ry", svgNumber(outline.box.height / 2));
      return ellipse;
    }
    case "polygon": {
      const polygon = ownerDocument.createElementNS(svgNamespace, "polygon");
      polygon.setAttribute(
        "points",
        outline.points.map((point) => svgPoint(point)).join(" "),
      );
      return polygon;
    }
    case "path": {
      const path = ownerDocument.createElementNS(svgNamespace, "path");
      path.setAttribute("d", pathDataFromProjection(outline));
      return path;
    }
  }
}

function applyShapeStyle(element, style) {
  element.setAttribute("fill", style.fill);
  element.setAttribute("stroke", style.stroke);
  element.setAttribute("stroke-width", svgNumber(style.strokeWidth));
  element.setAttribute("opacity", String(style.opacity));
  element.setAttribute("stroke-linejoin", style.lineJoin);
  element.setAttribute("vector-effect", "non-scaling-stroke");
  if (style.dash.length > 0) {
    element.setAttribute(
      "stroke-dasharray",
      style.dash.map(svgNumber).join(" "),
    );
  }
}

function pathSegmentCommand(segment) {
  switch (segment.kind) {
    case "line":
      return `L ${svgPoint(segment.end)}`;
    case "quadratic":
      return `Q ${svgPoint(segment.control)} ${svgPoint(segment.end)}`;
    case "cubic":
      return `C ${svgPoint(segment.control1)} ${svgPoint(segment.control2)} ${svgPoint(segment.end)}`;
    case "arc":
      return [
        "A",
        svgNumber(segment.radiusX),
        svgNumber(segment.radiusY),
        svgNumber(-segment.rotation),
        segment.largeArc ? "1" : "0",
        segment.clockwise ? "0" : "1",
        svgPoint(segment.end),
      ].join(" ");
  }
}

function positionHtmlBox(element, box) {
  const left = ((box.x - box.width / 2) / slideWidth) * 100;
  const bottom = ((box.y - box.height / 2) / slideHeight) * 100;
  const width = (box.width / slideWidth) * 100;
  const height = (box.height / slideHeight) * 100;
  if (![left, bottom, width, height].every(Number.isFinite)) {
    throw new ProductProjectionError("Node box cannot be positioned in the DOM");
  }
  element.style.left = `${left}%`;
  element.style.bottom = `${bottom}%`;
  element.style.width = `${width}%`;
  element.style.height = `${height}%`;
}

function handlePoints(box) {
  const left = box.x - box.width / 2;
  const right = box.x + box.width / 2;
  const bottom = box.y - box.height / 2;
  const top = box.y + box.height / 2;
  const centreX = box.x;
  const centreY = box.y;
  return [
    { x: left, y: bottom },
    { x: centreX, y: bottom },
    { x: right, y: bottom },
    { x: right, y: centreY },
    { x: right, y: top },
    { x: centreX, y: top },
    { x: left, y: top },
    { x: left, y: centreY },
  ];
}

function pointerDistance(startX, startY, currentX, currentY) {
  return Math.hypot(currentX - startX, currentY - startY);
}

function snapshotBounds(value) {
  const bounds = {
    left: value?.left,
    right: value?.right,
    top: value?.top,
    bottom: value?.bottom,
    width: value?.width,
    height: value?.height,
  };
  return isUsableBounds(bounds) ? Object.freeze(bounds) : null;
}

function isUsableBounds(bounds) {
  return (
    bounds !== null &&
    typeof bounds === "object" &&
    Number.isFinite(bounds.left) &&
    Number.isFinite(bounds.right) &&
    Number.isFinite(bounds.top) &&
    Number.isFinite(bounds.bottom) &&
    Number.isFinite(bounds.width) &&
    Number.isFinite(bounds.height) &&
    bounds.width > 0 &&
    bounds.height > 0 &&
    bounds.right >= bounds.left &&
    bounds.bottom >= bounds.top
  );
}

function canonicalDecimal(value, precision) {
  const rounded = Math.round(value * 10 ** precision) / 10 ** precision;
  if (Object.is(rounded, -0) || rounded === 0) {
    return "0";
  }
  return rounded
    .toFixed(precision)
    .replace(/(?:\.0+|(\.\d+?)0+)$/, "$1");
}

function svgNumber(value) {
  return canonicalDecimal(value, geometryPrecision);
}

function svgPoint(point) {
  return `${svgNumber(point.x)} ${svgNumber(point.y)}`;
}

function expectRecord(value, path) {
  if (
    value === null ||
    typeof value !== "object" ||
    Array.isArray(value) ||
    Object.getPrototypeOf(value) !== Object.prototype
  ) {
    throw new ProductProjectionError(`${path} must be a plain record`);
  }
  return value;
}

function expectArray(value, path, maximum) {
  if (!Array.isArray(value)) {
    throw new ProductProjectionError(`${path} must be an array`);
  }
  if (value.length > maximum) {
    throw new ProductProjectionError(
      `${path} exceeds its ${maximum}-entry limit`,
    );
  }
  return value;
}

function expectRevision(value, path) {
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new ProductProjectionError(
      `${path} must be a non-negative safe integer`,
    );
  }
  return value;
}

function expectFiniteNumber(value, path) {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new ProductProjectionError(`${path} must be a finite number`);
  }
  return value;
}

function expectPositiveNumber(value, path) {
  const number = expectFiniteNumber(value, path);
  if (number <= 0) {
    throw new ProductProjectionError(`${path} must be positive`);
  }
  return number;
}

function expectNonNegativeNumber(value, path) {
  const number = expectFiniteNumber(value, path);
  if (number < 0) {
    throw new ProductProjectionError(`${path} must be non-negative`);
  }
  return number;
}

function expectUnitInterval(value, path) {
  const number = expectFiniteNumber(value, path);
  if (number < 0 || number > 1) {
    throw new ProductProjectionError(`${path} must be between zero and one`);
  }
  return number;
}

function expectBoolean(value, path) {
  if (typeof value !== "boolean") {
    throw new ProductProjectionError(`${path} must be a boolean`);
  }
  return value;
}

function expectText(value, path) {
  if (
    typeof value !== "string" ||
    value.length === 0 ||
    value.length > maximumTextLength ||
    /[\u0000-\u001f\u007f]/u.test(value)
  ) {
    throw new ProductProjectionError(
      `${path} must be non-empty display text without controls`,
    );
  }
  return value;
}

function expectIdentifier(value, path) {
  if (
    typeof value !== "string" ||
    value.length > 512 ||
    !identifierPattern.test(value)
  ) {
    throw new ProductProjectionError(`${path} must be a valid identifier`);
  }
  return value;
}

function expectDecimal(value, path) {
  if (
    typeof value !== "string" ||
    !decimalPattern.test(value) ||
    !Number.isFinite(Number(value))
  ) {
    throw new ProductProjectionError(`${path} must be a finite decimal string`);
  }
  return value;
}

function expectPaint(value, path) {
  const paint = expectText(value, path).trim();
  if (
    paint.length > 256 ||
    /url\s*\(/iu.test(paint) ||
    /[;{}\\]/u.test(paint)
  ) {
    throw new ProductProjectionError(
      `${path} must be a direct CSS paint without external resources`,
    );
  }
  return paint;
}

function expectOneOf(value, allowed, path) {
  const choices = allowed instanceof Set ? allowed : new Set(allowed);
  if (typeof value !== "string" || !choices.has(value)) {
    throw new ProductProjectionError(
      `${path} must be one of ${Array.from(choices).join(", ")}`,
    );
  }
  return value;
}

function requireExactKeys(record, expected, path) {
  requireAllowedKeys(record, expected, path);
  for (const key of expected) {
    if (!Object.hasOwn(record, key)) {
      throw new ProductProjectionError(`${path}.${key} is required`);
    }
  }
}

function requireAllowedKeys(record, allowed, path) {
  const keys = Object.keys(record);
  const allowedSet = new Set(allowed);
  for (const key of keys) {
    if (!allowedSet.has(key)) {
      throw new ProductProjectionError(`${path}.${key} is not supported`);
    }
  }
}

function requireContainer(container, label) {
  if (
    container === null ||
    typeof container !== "object" ||
    typeof container.append !== "function" ||
    container.ownerDocument === null
  ) {
    throw new TypeError(`${label} requires a DOM container`);
  }
}

function deepFreeze(value) {
  if (value !== null && typeof value === "object" && !Object.isFrozen(value)) {
    Object.freeze(value);
    for (const child of Object.values(value)) {
      deepFreeze(child);
    }
  }
  return value;
}
