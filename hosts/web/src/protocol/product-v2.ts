const maximumSourceBytes = 8 * 1024 * 1024;
const maximumCoordinateLength = 128;
const maximumPaintMagnitude = 1_000_000_000;
const nodeIdPattern = /^[A-Za-z_][A-Za-z0-9_-]*$/;
const base16Pattern = /^(?:[0-9a-f]{2})*$/;
const protocol = "slideblaster.product/2";
const slideWidth = 16;
const slideHeight = 9;
const pointerPrecision = 6;

const successKinds = new Set([
  "source_opened",
  "workspace_snapshot",
  "paint_acknowledged",
  "pointer_updated",
  "pointer_preview_rejected",
  "pointer_committed",
  "view_updated",
  "undo",
  "redo",
  "source_unchanged",
  "source_replaced",
  "node_activated",
  "slide_created",
  "slide_selected",
]);
const errorCodes = new Set([
  "malformed_json",
  "unsupported_protocol",
  "unknown_command",
  "invalid_field",
  "workspace_not_open",
  "stale_revision",
  "paint_not_offered",
  "paint_fence_mismatch",
  "node_not_admitted",
  "node_not_selected",
  "session_id_exhausted",
  "gesture_id_exhausted",
  "gesture_not_active",
  "gesture_id_mismatch",
  "gesture_not_previewed",
  "gesture_stale_revision",
  "gesture_stale_paint",
  "history_unavailable",
  "analysis_rejected",
  "render_rejected",
  "paint_rejected",
  "canvas_edit_rejected",
  "canvas_projection_rejected",
  "canvas_verification_rejected",
  "deck_not_ready",
  "active_slide_missing",
  "deck_projection_rejected",
  "surface_not_active",
]);
const readinessValues = new Set(["pending", "syntax_only", "ready"]);
const authorityValues = new Set(["none", "paint_pending", "writable", "inert"]);
const surfaceKinds = new Set(["audience", "notes"]);
const layerKinds = new Set([
  "background",
  "rear_furniture",
  "connector",
  "object",
  "content",
  "front_furniture",
]);
const elementKinds = new Set(["node", "connector", "group"]);
const guideKinds = new Set(["point", "alignment", "spacing", "binding"]);
const maximumGuides = 4_096;

export const productProtocolV2 = protocol;

export class ProductV2WireError extends Error {
  constructor(message) {
    super(message);
    this.name = "ProductV2WireError";
  }
}

export class ProductV2RejectedError extends Error {
  response: any;
  constructor(response) {
    super(`${response.error.code}: ${response.error.message}`);
    this.name = "ProductV2RejectedError";
    this.response = response;
  }
}

/** Parse and validate a complete product/2 response before it reaches the DOM. */
export function decodeProductV2Response(raw) {
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new ProductV2WireError("response must be valid JSON");
  }
  return validateProductV2Response(parsed);
}

/** Validate and defensively copy the exact closed Haskell response schema. */
export function validateProductV2Response(value) {
  const response = record(value, "response");
  literal(response.protocol, protocol, "response.protocol");
  boolean(response.ok, "response.ok");
  if (!response.ok) {
    exactKeys(response, ["protocol", "ok", "kind", "error"], "response");
    literal(response.kind, "error", "response.kind");
    const failure = record(response.error, "response.error");
    exactKeys(failure, ["code", "message"], "response.error");
    oneOf(failure.code, errorCodes, "response.error.code");
    safeText(failure.message, "response.error.message", 2048);
    return deepFreeze({
      protocol,
      ok: false,
      kind: "error",
      error: { code: failure.code, message: failure.message },
    });
  }

  exactKeys(response, ["protocol", "ok", "kind", "actions", "workspace"], "response");
  oneOf(response.kind, successKinds, "response.kind");
  if (!Array.isArray(response.actions) || response.actions.length > 64) {
    fail("response.actions must be a bounded array");
  }
  return deepFreeze({
    protocol,
    ok: true,
    kind: response.kind,
    actions: response.actions.map((action, index) =>
      validateHostAction(action, `response.actions[${index}]`),
    ),
    workspace: validateWorkspace(response.workspace),
  });
}

export function validateWorkspace(value) {
  const workspace = record(value, "workspace");
  exactKeys(
    workspace,
    [
      "source", "readiness", "canUndo", "canRedo", "selection",
      "authority", "renderOffer", "displayedRender", "pointer", "preview",
      "navigator",
    ],
    "workspace",
  );
  const source = record(workspace.source, "workspace.source");
  exactKeys(source, ["revision", "base16"], "workspace.source");
  const revision = safeUnsigned(source.revision, "workspace.source.revision");
  const base16 = validateBase16(source.base16, "workspace.source.base16");
  const readiness = oneOf(workspace.readiness, readinessValues, "workspace.readiness");
  const canUndo = boolean(workspace.canUndo, "workspace.canUndo");
  const canRedo = boolean(workspace.canRedo, "workspace.canRedo");
  const selection = workspace.selection === null
    ? null
    : nodeId(workspace.selection, "workspace.selection");
  const authority = oneOf(workspace.authority, authorityValues, "workspace.authority");
  const renderOffer = workspace.renderOffer === null
    ? null
    : validateCorrelatedRender(workspace.renderOffer, "workspace.renderOffer");
  const displayedRender = workspace.displayedRender === null
    ? null
    : validateCorrelatedRender(workspace.displayedRender, "workspace.displayedRender");
  const pointer = validatePointerProjection(workspace.pointer, "workspace.pointer");
  const preview = workspace.preview === null
    ? null
    : validatePreview(workspace.preview, "workspace.preview");
  const navigator = validateNavigator(workspace.navigator, "workspace.navigator");

  if (renderOffer !== null && renderOffer.fence.revision !== revision) {
    fail("workspace.renderOffer must target the current source revision");
  }
  if (displayedRender !== null && displayedRender.fence.revision > revision) {
    fail("workspace.displayedRender cannot be newer than source");
  }
  if (readiness === "syntax_only" && renderOffer !== null) {
    fail("syntax-only workspace cannot offer a render");
  }
  if (authority === "paint_pending" && renderOffer === null) {
    fail("paint_pending authority requires a render offer");
  }
  if (authority === "writable" && displayedRender === null) {
    fail("writable authority requires a displayed render");
  }
  if (selection !== null) {
    const projections = [renderOffer, displayedRender].filter(Boolean);
    if (!projections.some((projection) => projectedNodeIds(projection).has(selection))) {
      fail("workspace.selection must identify a projected node");
    }
  }
  if (pointer.phase === "idle" && pointer.pointerId !== null) {
    fail("idle pointer projection must not retain an id");
  }
  if (pointer.phase !== "idle" && pointer.pointerId === null) {
    fail("active pointer projection requires an id");
  }
  if (preview !== null && (pointer.phase !== "dragging" || selection !== preview.nodeId)) {
    fail("workspace.preview must match dragging selection");
  }

  return deepFreeze({
    source: { revision, base16 }, readiness, canUndo, canRedo, selection,
    authority, renderOffer, displayedRender, pointer, preview, navigator,
  });
}

function validateHostAction(value, path) {
  const action = record(value, path);
  const kind = oneOf(
    action.kind,
    new Set([
      "capture_pointer", "release_pointer", "repaint", "show_preview", "clear_preview", "focus_node",
    ]),
    `${path}.kind`,
  );
  if (["capture_pointer", "release_pointer"].includes(kind)) {
    exactKeys(action, ["kind", "pointerId"], path);
    return { kind, pointerId: safeUnsigned(action.pointerId, `${path}.pointerId`) };
  }
  if (kind === "focus_node") {
    exactKeys(action, ["kind", "surface", "nodeId"], path);
    return { kind, surface: validateSurface(action.surface, `${path}.surface`), nodeId: nodeId(action.nodeId, `${path}.nodeId`) };
  }
  if (kind === "repaint" || kind === "clear_preview") {
    exactKeys(action, ["kind"], path);
    return { kind };
  }
  exactKeys(action, ["kind", "nodeId", "centre", "freeDrag", "guides"], path);
  return {
    kind,
    nodeId: nodeId(action.nodeId, `${path}.nodeId`),
    centre: validatePoint(action.centre, `${path}.centre`),
    freeDrag: boolean(action.freeDrag, `${path}.freeDrag`),
    guides: validateGuides(action.guides, `${path}.guides`),
  };
}

function validatePointerProjection(value, path) {
  const pointer = record(value, path);
  exactKeys(pointer, ["phase", "pointerId"], path);
  return {
    phase: oneOf(pointer.phase, new Set(["idle", "pressed", "dragging"]), `${path}.phase`),
    pointerId: pointer.pointerId === null ? null : safeUnsigned(pointer.pointerId, `${path}.pointerId`),
  };
}

function validatePreview(value, path) {
  const preview = record(value, path);
  exactKeys(preview, ["nodeId", "centre", "freeDrag", "guides", "outcome"], path);
  return {
    nodeId: nodeId(preview.nodeId, `${path}.nodeId`),
    centre: validatePoint(preview.centre, `${path}.centre`),
    freeDrag: boolean(preview.freeDrag, `${path}.freeDrag`),
    guides: validateGuides(preview.guides, `${path}.guides`),
    outcome: oneOf(preview.outcome, new Set(["verified", "no_op"]), `${path}.outcome`),
  };
}

function validateGuides(value, path) {
  if (!Array.isArray(value) || value.length > maximumGuides) {
    fail(`${path} must be a bounded array`);
  }
  return value.map((guide, index) => validateGuide(guide, `${path}[${index}]`));
}

function validateGuide(value, path) {
  const guide = record(value, path);
  exactKeys(guide, ["kind", "start", "end"], path);
  return {
    kind: oneOf(guide.kind, guideKinds, `${path}.kind`),
    start: validatePoint(guide.start, `${path}.start`),
    end: validatePoint(guide.end, `${path}.end`),
  };
}

function validateNavigator(value, path) {
  const navigator = record(value, path);
  exactKeys(navigator, ["activeIndex", "activeFrame", "slideCount", "items", "previous", "next", "newSlide"], path);
  const activeIndex = safeUnsigned(navigator.activeIndex, `${path}.activeIndex`);
  const slideCount = safeUnsigned(navigator.slideCount, `${path}.slideCount`);
  if (!Array.isArray(navigator.items) || navigator.items.length !== slideCount) {
    fail(`${path}.items must match slideCount`);
  }
  const items = navigator.items.map((value, index) => {
    const itemPath = `${path}.items[${index}]`;
    const item = record(value, itemPath);
    exactKeys(item, ["frame", "title", "audience", "notes"], itemPath);
    const frame = safeText(item.frame, `${itemPath}.frame`, 512);
    const audience = item.audience === null ? null : validatePlan(item.audience, `${itemPath}.audience`);
    const notes = item.notes === null ? null : validatePlan(item.notes, `${itemPath}.notes`);
    if (audience !== null && (audience.surface.frame !== frame || audience.surface.kind !== "audience")) {
      fail(`${itemPath}.audience must match the frame audience surface`);
    }
    if (notes !== null && (notes.surface.frame !== frame || notes.surface.kind !== "notes")) {
      fail(`${itemPath}.notes must match the frame notes surface`);
    }
    return {
      frame,
      title: safeText(item.title, `${itemPath}.title`, 2048),
      audience,
      notes,
    };
  });
  const activeFrame = navigator.activeFrame === null ? null : safeText(navigator.activeFrame, `${path}.activeFrame`, 512);
  if (slideCount === 0) {
    if (activeFrame !== null || activeIndex !== 0) fail(`${path} empty state is inconsistent`);
  } else if (activeIndex >= slideCount || items[activeIndex].frame !== activeFrame) {
    fail(`${path} must identify the active stable frame`);
  }
  return {
    activeIndex, activeFrame, slideCount, items,
    previous: validateAvailability(navigator.previous, `${path}.previous`, new Set(["only_slide_available", "first_slide"])),
    next: validateAvailability(navigator.next, `${path}.next`, new Set(["only_slide_available", "last_slide"])),
    newSlide: validateAvailability(navigator.newSlide, `${path}.newSlide`, new Set(["source_not_ready"])),
  };
}

function validateAvailability(value, path, reasons) {
  const availability = record(value, path);
  exactKeys(availability, ["enabled", "disabledReason"], path);
  const enabled = boolean(availability.enabled, `${path}.enabled`);
  if (enabled) {
    if (availability.disabledReason !== null) fail(`${path}.disabledReason must be null when enabled`);
    return { enabled: true, disabledReason: null };
  }
  return {
    enabled: false,
    disabledReason: oneOf(availability.disabledReason, reasons, `${path}.disabledReason`),
  };
}

function validateCorrelatedRender(value, path) {
  const correlated = record(value, path);
  exactKeys(correlated, ["fence", "plan"], path);
  const fence = validateFence(correlated.fence, `${path}.fence`);
  const plan = validatePlan(correlated.plan, `${path}.plan`);
  if (
    fence.revision !== plan.revision ||
    fence.ticket !== plan.ticket ||
    !sameSurface(fence.surface, plan.surface)
  ) {
    fail(`${path} plan does not match its paint fence`);
  }
  return deepFreeze({ fence, plan });
}

export function validateFence(value, path = "paint") {
  const fence = record(value, path);
  exactKeys(fence, ["session", "revision", "ticket", "surface"], path);
  return deepFreeze({
    session: safeUnsigned(fence.session, `${path}.session`),
    revision: safeUnsigned(fence.revision, `${path}.revision`),
    ticket: safeUnsigned(fence.ticket, `${path}.ticket`),
    surface: validateSurface(fence.surface, `${path}.surface`),
  });
}

function validatePlan(value, path) {
  const plan = record(value, path);
  exactKeys(
    plan,
    ["protocol", "revision", "ticket", "surface", "coordinateSpace", "size", "layers"],
    path,
  );
  literal(plan.protocol, protocol, `${path}.protocol`);
  literal(plan.coordinateSpace, "slide_16x9_y_up", `${path}.coordinateSpace`);
  const surface = validateSurface(plan.surface, `${path}.surface`);
  const size = validateSize(plan.size, `${path}.size`);
  if (size.width.number !== slideWidth || size.height.number !== slideHeight) {
    fail(`${path}.size must be exactly 16 by 9`);
  }
  if (!Array.isArray(plan.layers) || plan.layers.length === 0 || plan.layers.length > 32) {
    fail(`${path}.layers must be a non-empty bounded array`);
  }
  const layers = plan.layers.map((layer, index) =>
    validateLayer(layer, `${path}.layers[${index}]`, surface),
  );
  return deepFreeze({
    protocol,
    revision: safeUnsigned(plan.revision, `${path}.revision`),
    ticket: safeUnsigned(plan.ticket, `${path}.ticket`),
    surface,
    coordinateSpace: "slide_16x9_y_up",
    size,
    layers,
  });
}

function validateLayer(value, path, planSurface) {
  const layer = record(value, path);
  exactKeys(layer, ["kind", "items"], path);
  const kind = oneOf(layer.kind, layerKinds, `${path}.kind`);
  if (!Array.isArray(layer.items) || layer.items.length > 10_000) {
    fail(`${path}.items must be a bounded array`);
  }
  return {
    kind,
    items: layer.items.map((item, index) =>
      validateItem(item, `${path}.items[${index}]`, planSurface),
    ),
  };
}

function validateItem(value, path, planSurface) {
  const item = record(value, path);
  const kind = oneOf(item.kind, new Set(["rectangle", "line"]), `${path}.kind`);
  if (kind === "rectangle") {
    exactKeys(item, ["kind", "identity", "box", "hitTarget", "interaction"], path);
    const identity = validateIdentity(item.identity, `${path}.identity`);
    const box = validateBox(item.box, `${path}.box`);
    const hitTarget = validateBox(item.hitTarget, `${path}.hitTarget`);
    const interaction = validateInteraction(item.interaction, `${path}.interaction`);
    requireSurface(identity.surface, planSurface, `${path}.identity.surface`);
    if (identity.element.kind !== "node") {
      fail(`${path}.identity.element must be a node for a rectangle`);
    }
    if (
      interaction.kind !== "select_element" ||
      !sameSurface(interaction.surface, identity.surface) ||
      !sameElement(interaction.element, identity.element)
    ) {
      fail(`${path}.interaction must select the rectangle identity`);
    }
    return { kind, identity, box, hitTarget, interaction };
  }

  exactKeys(item, ["kind", "identity", "start", "end", "interaction"], path);
  const identity = validateIdentity(item.identity, `${path}.identity`);
  const start = validatePoint(item.start, `${path}.start`);
  const end = validatePoint(item.end, `${path}.end`);
  const interaction = validateInteraction(item.interaction, `${path}.interaction`);
  requireSurface(identity.surface, planSurface, `${path}.identity.surface`);
  if (identity.element.kind !== "connector" || interaction.kind !== "inert") {
    fail(`${path} line must be an inert connector`);
  }
  return { kind, identity, start, end, interaction };
}

function validateIdentity(value, path) {
  const identity = record(value, path);
  exactKeys(identity, ["surface", "element", "part"], path);
  return {
    surface: validateSurface(identity.surface, `${path}.surface`),
    element: validateElement(identity.element, `${path}.element`),
    part: safeText(identity.part, `${path}.part`, 512, true),
  };
}

function validateElement(value, path) {
  const element = record(value, path);
  exactKeys(element, ["kind", "id"], path);
  return {
    kind: oneOf(element.kind, elementKinds, `${path}.kind`),
    id: nodeId(element.id, `${path}.id`),
  };
}

function validateInteraction(value, path) {
  const interaction = record(value, path);
  const kind = oneOf(
    interaction.kind,
    new Set(["inert", "select_element"]),
    `${path}.kind`,
  );
  if (kind === "inert") {
    exactKeys(interaction, ["kind"], path);
    return { kind };
  }
  exactKeys(interaction, ["kind", "surface", "element"], path);
  return {
    kind,
    surface: validateSurface(interaction.surface, `${path}.surface`),
    element: validateElement(interaction.element, `${path}.element`),
  };
}

function validateSurface(value, path) {
  const surface = record(value, path);
  exactKeys(surface, ["frame", "kind"], path);
  return {
    frame: nodeId(surface.frame, `${path}.frame`),
    kind: oneOf(surface.kind, surfaceKinds, `${path}.kind`),
  };
}

function validatePoint(value, path) {
  const point = record(value, path);
  exactKeys(point, ["x", "y"], path);
  return {
    x: exactCoordinate(point.x, `${path}.x`),
    y: exactCoordinate(point.y, `${path}.y`),
  };
}

function validateSize(value, path) {
  const size = record(value, path);
  exactKeys(size, ["width", "height"], path);
  const width = exactCoordinate(size.width, `${path}.width`);
  const height = exactCoordinate(size.height, `${path}.height`);
  if (width.number <= 0 || height.number <= 0) {
    fail(`${path} dimensions must be positive`);
  }
  return { width, height };
}

function validateBox(value, path) {
  const box = record(value, path);
  exactKeys(box, ["center", "size"], path);
  return {
    center: validatePoint(box.center, `${path}.center`),
    size: validateSize(box.size, `${path}.size`),
  };
}

/** Convert an exact Haskell rational string to a bounded finite paint number. */
export function exactCoordinate(value, path = "coordinate") {
  if (typeof value !== "string" || value.length === 0 || value.length > maximumCoordinateLength) {
    fail(`${path} must be a bounded exact number string`);
  }
  const match = /^(-?)(0|[1-9][0-9]*)(?:\.([0-9]+)|\/([1-9][0-9]*))?$/.exec(value);
  if (match === null) {
    return fail(`${path} must be a canonical exact number string`);
  }
  let numerator = BigInt(match[2]);
  let denominator = 1n;
  if (match[3] !== undefined) {
    denominator = 10n ** BigInt(match[3].length);
    numerator = numerator * denominator + BigInt(match[3]);
  } else if (match[4] !== undefined) {
    denominator = BigInt(match[4]);
  }
  if (match[1] === "-") {
    numerator = -numerator;
  }
  const numericNumerator = Number(numerator);
  const numericDenominator = Number(denominator);
  const number = numericNumerator / numericDenominator;
  if (
    !Number.isFinite(numericNumerator) ||
    !Number.isFinite(numericDenominator) ||
    !Number.isFinite(number) ||
    Math.abs(number) > maximumPaintMagnitude
  ) {
    fail(`${path} cannot be converted safely for paint`);
  }
  return deepFreeze({ exact: value, number });
}

export function validateBase16(value, path = "base16") {
  if (
    typeof value !== "string" ||
    value.length > maximumSourceBytes * 2 ||
    !base16Pattern.test(value)
  ) {
    fail(`${path} must be bounded lower-case even-length base16`);
  }
  return value;
}

export function bytesFromBase16(value) {
  const valid = validateBase16(value);
  const bytes = new Uint8Array(valid.length / 2);
  for (let index = 0; index < valid.length; index += 2) {
    bytes[index / 2] = Number.parseInt(valid.slice(index, index + 2), 16);
  }
  return bytes;
}

export function base16FromBytes(value) {
  if (!(value instanceof Uint8Array) || value.byteLength > maximumSourceBytes) {
    fail("source must be a bounded Uint8Array");
  }
  return Array.from(value, (byte: number) => byte.toString(16).padStart(2, "0")).join("");
}

/** Convert a finite in-bounds browser pointer to exact 16×9 y-up decimals. */
export function clientPointToSlide(clientX, clientY, bounds) {
  if (
    !Number.isFinite(clientX) ||
    !Number.isFinite(clientY) ||
    !usableBounds(bounds) ||
    clientX < bounds.left ||
    clientX > bounds.right ||
    clientY < bounds.top ||
    clientY > bounds.bottom
  ) {
    return null;
  }
  return Object.freeze({
    x: pointerDecimal(((clientX - bounds.left) / bounds.width) * slideWidth),
    y: pointerDecimal(slideHeight - ((clientY - bounds.top) / bounds.height) * slideHeight),
  });
}

/** Convert a finite browser pointer to clamped exact 16×9 y-up decimals. */
export function clientPointToClampedSlide(clientX, clientY, bounds) {
  if (!Number.isFinite(clientX) || !Number.isFinite(clientY) || !usableBounds(bounds)) {
    return null;
  }
  const clampedX = Math.min(Math.max(clientX, bounds.left), bounds.right);
  const clampedY = Math.min(Math.max(clientY, bounds.top), bounds.bottom);
  return Object.freeze({
    x: pointerDecimal(((clampedX - bounds.left) / bounds.width) * slideWidth),
    y: pointerDecimal(slideHeight - ((clampedY - bounds.top) / bounds.height) * slideHeight),
  });
}

export function requestOpenSource(sourceBase16) {
  return request("open_source", { sourceBase16: validateBase16(sourceBase16) });
}

export function requestWorkspaceSnapshot() {
  return request("workspace_snapshot");
}

export function requestAcknowledgePaint(paint) {
  return request("acknowledge_paint", { paint: wireFence(paint) });
}

export function requestPointerEvent(event) {
  return request("pointer_event", { event: validatePointerEvent(event) });
}

export function requestActivateNode(surfaceValue, nodeIdValue) {
  return request("activate_node", {
    surface: validateSurface(surfaceValue, "surface"),
    nodeId: nodeId(nodeIdValue, "nodeId"),
  });
}

export function requestSelectSlide(frame) {
  return request("select_slide", { frame: nodeId(frame, "frame") });
}

export function requestNewSlide(revision) {
  return request("new_slide", { revision: safeUnsigned(revision, "revision") });
}

export function requestViewCommand(viewCommand) {
  return request("view_command", {
    viewCommand: oneOf(
      viewCommand,
      new Set(["previous_slide", "next_slide"]),
      "viewCommand",
    ),
  });
}

export function requestHistory(command, revision) {
  if (command !== "undo" && command !== "redo") {
    fail("history command must be undo or redo");
  }
  return request(command, { revision: safeUnsigned(revision, "revision") });
}

export function requestReplaceSource(revision, sourceBase16) {
  return request("replace_source", {
    revision: safeUnsigned(revision, "revision"),
    sourceBase16: validateBase16(sourceBase16),
  });
}

function validatePointerEvent(value) {
  const event = record(value, "event");
  const type = oneOf(event.type, new Set(["down", "move", "up", "cancel", "lost_capture"]), "event.type");
  if (type === "cancel" || type === "lost_capture") {
    exactKeys(event, ["type", "pointerId"], "event");
    return { type, pointerId: safeUnsigned(event.pointerId, "event.pointerId") };
  }
  const keys = ["type", "pointerId", "pointerType", "button", "primary", "cssPoint", "slidePoint", "modifiers"];
  if (type === "down") keys.push("target");
  exactKeys(event, keys, "event");
  const result: Record<string, any> = {
    type,
    pointerId: safeUnsigned(event.pointerId, "event.pointerId"),
    pointerType: oneOf(event.pointerType, new Set(["mouse", "pen", "touch"]), "event.pointerType"),
    button: safeUnsigned(event.button, "event.button"),
    primary: boolean(event.primary, "event.primary"),
    cssPoint: validateWirePoint(event.cssPoint, "event.cssPoint"),
    slidePoint: validateWirePoint(event.slidePoint, "event.slidePoint"),
    modifiers: validateModifiers(event.modifiers),
  };
  if (type === "down") result.target = validatePointerTarget(event.target);
  return result;
}

function validateWirePoint(value, path) {
  const point = record(value, path);
  exactKeys(point, ["x", "y"], path);
  return {
    x: exactCoordinate(point.x, `${path}.x`).exact,
    y: exactCoordinate(point.y, `${path}.y`).exact,
  };
}

function validateModifiers(value) {
  const modifiers = record(value, "event.modifiers");
  exactKeys(modifiers, ["alt", "shift", "control", "meta"], "event.modifiers");
  return {
    alt: boolean(modifiers.alt, "event.modifiers.alt"),
    shift: boolean(modifiers.shift, "event.modifiers.shift"),
    control: boolean(modifiers.control, "event.modifiers.control"),
    meta: boolean(modifiers.meta, "event.modifiers.meta"),
  };
}

function validatePointerTarget(value) {
  const target = record(value, "event.target");
  const kind = oneOf(target.kind, new Set(["canvas", "node"]), "event.target.kind");
  if (kind === "canvas") {
    exactKeys(target, ["kind"], "event.target");
    return { kind };
  }
  exactKeys(target, ["kind", "surface", "nodeId"], "event.target");
  return { kind, surface: validateSurface(target.surface, "event.target.surface"), nodeId: nodeId(target.nodeId, "event.target.nodeId") };
}

function request(command, fields = {}) {
  return deepFreeze({ protocol, command, ...fields });
}

function wireFence(value) {
  const fence = validateFence(value);
  return {
    session: fence.session,
    revision: fence.revision,
    ticket: fence.ticket,
    surface: { ...fence.surface },
  };
}

function projectedNodeIds(correlated) {
  const ids = new Set();
  for (const layer of correlated.plan.layers) {
    for (const item of layer.items) {
      if (item.kind === "rectangle") {
        ids.add(item.identity.element.id);
      }
    }
  }
  return ids;
}

function pointerDecimal(value) {
  const rounded = Math.round(value * 10 ** pointerPrecision) / 10 ** pointerPrecision;
  if (rounded === 0 || Object.is(rounded, -0)) {
    return "0";
  }
  return rounded.toFixed(pointerPrecision).replace(/(?:\.0+|(\.\d+?)0+)$/, "$1");
}

function usableBounds(bounds) {
  return (
    bounds !== null &&
    typeof bounds === "object" &&
    [bounds.left, bounds.right, bounds.top, bounds.bottom, bounds.width, bounds.height].every(
      (coordinate) => Number.isFinite(coordinate),
    ) &&
    bounds.width > 0 &&
    bounds.height > 0 &&
    bounds.right >= bounds.left &&
    bounds.bottom >= bounds.top
  );
}

function sameFence(left, right) {
  return (
    left.session === right.session &&
    left.revision === right.revision &&
    left.ticket === right.ticket &&
    sameSurface(left.surface, right.surface)
  );
}

function sameSurface(left, right) {
  return left.frame === right.frame && left.kind === right.kind;
}

function requireSurface(actual, expected, path) {
  if (!sameSurface(actual, expected)) {
    fail(`${path} does not match the plan surface`);
  }
}

function sameElement(left, right) {
  return left.kind === right.kind && left.id === right.id;
}

function nodeId(value, path) {
  if (typeof value !== "string" || value.length > 512 || !nodeIdPattern.test(value)) {
    fail(`${path} must be a source-friendly identifier`);
  }
  return value;
}

function safeUnsigned(value, path) {
  if (!Number.isSafeInteger(value) || value < 0) {
    fail(`${path} must be a non-negative browser-safe integer`);
  }
  return value;
}

function safeText(value, path, maximum, allowControls = false) {
  if (
    typeof value !== "string" ||
    value.length === 0 ||
    value.length > maximum ||
    (!allowControls && /[\u0000-\u001f\u007f]/u.test(value))
  ) {
    fail(`${path} must be bounded safe text`);
  }
  return value;
}

function boolean(value, path) {
  if (typeof value !== "boolean") {
    fail(`${path} must be boolean`);
  }
  return value;
}

function literal(value, expected, path) {
  if (value !== expected) {
    fail(`${path} must equal ${expected}`);
  }
  return value;
}

function oneOf(value, allowed, path) {
  if (typeof value !== "string" || !allowed.has(value)) {
    fail(`${path} is not an allowed value`);
  }
  return value;
}

function record(value, path) {
  if (
    value === null ||
    typeof value !== "object" ||
    Array.isArray(value) ||
    Object.getPrototypeOf(value) !== Object.prototype
  ) {
    fail(`${path} must be a plain record`);
  }
  return value;
}

function exactKeys(value, expected, path) {
  const actual = Object.keys(value);
  for (const key of expected) {
    if (!Object.hasOwn(value, key)) {
      fail(`${path}.${key} is required`);
    }
  }
  for (const key of actual) {
    if (!expected.includes(key)) {
      fail(`${path}.${key} is not supported`);
    }
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

function fail(message: string): never {
  throw new ProductV2WireError(message);
}
