import { installHostCall } from "./capabilities/host-call.ts";
import { redactProtocolExchange } from "./product-v2-policy.ts";
import {
  base16FromBytes,
  bytesFromBase16,
  decodeProductV2Response,
  ProductV2RejectedError,
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
} from "./protocol/product-v2.ts";
import {
  createProductV2RenderSurface,
  createProductV2StaticSurface,
} from "./ui/product-v2-renderer.ts";
import { createCanvasViewport } from "./ui/viewport.ts";
import { loadSlideBlasterReactor } from "./wasm/load-reactor.ts";

const fixtureUrl = new URL("./fixtures/demo.slide", document.baseURI);
const strictDecoder = new TextDecoder("utf-8", { fatal: true });
const encoder = new TextEncoder();
const protocolTrace: any[] = [];
function q<T extends HTMLElement = HTMLElement>(selector: string): T {
  const element = document.querySelector<T>(selector);
  if (element === null) throw new Error(`Missing element ${selector}`);
  return element;
}
const elements = {
  deck: q("#deck"),
  deckAdd: q<HTMLButtonElement>("#deck-add"),
  deckCanvas: q("#deck-canvas"),
  deckRail: q("#deck-rail"),
  documentTitle: q("#doc-title"),
  newSlide: q<HTMLButtonElement>("#new-slide"),
  output: q("#output"),
  redo: q<HTMLButtonElement>("#redo"),
  source: q<HTMLTextAreaElement>("#source"),
  sourcePane: q("#editor-pane"),
  sourceToggle: q<HTMLButtonElement>("#view-source"),
  status: q("#status"),
  thumbs: q("#slide-items"),
  undo: q<HTMLButtonElement>("#undo"),
  workspace: q("#workspace"),
  zoomIn: q<HTMLButtonElement>("#zoom-in"),
  zoomOut: q<HTMLButtonElement>("#zoom-out"),
  zoomReadout: q<HTMLButtonElement>("#zoom-readout"),
  zoomFit: q<HTMLButtonElement>("#zoom-fit"),
};

let reactor: any = null;
let workspace: any = null;
let renderController: any = null;
let sourceDirty = false;
let draftGeneration = 0;
let testDispatchGate: any = null;
let transport = Promise.resolve();
let deckStructureKey: string | null = null;
let activeFrameKey: string | null = null;
const viewport = createCanvasViewport({
  frame: elements.deck,
  canvas: elements.deckCanvas,
  activeSlide: activeDeckSlide,
  onChange: projectViewport,
});

installHostCall();
bindInterface();
setControlsUnavailable();

try {
  reactor = await loadSlideBlasterReactor();
  const response = await fetch(fixtureUrl);
  if (!response.ok) throw new Error(`Fixture HTTP ${response.status}`);
  const bytes = new Uint8Array(await response.arrayBuffer());
  await enqueue(requestOpenSource(base16FromBytes(bytes)), { explicitSourceLoad: true });
} catch (failure) {
  showFailure(failure, "Couldn’t open the presentation");
}

function bindInterface() {
  elements.sourceToggle.addEventListener("click", () => {
    const visible = elements.workspace.dataset.sourceVisible !== "false";
    elements.workspace.dataset.sourceVisible = String(!visible);
    elements.sourceToggle.setAttribute("aria-pressed", String(!visible));
  });
  elements.undo.addEventListener("click", () => sendHistory("undo"));
  elements.redo.addEventListener("click", () => sendHistory("redo"));
  elements.newSlide.addEventListener("click", addSlide);
  elements.deckAdd.addEventListener("click", addSlide);
  elements.zoomOut.addEventListener("click", () => viewport.applyZoomCommand("out"));
  elements.zoomIn.addEventListener("click", () => viewport.applyZoomCommand("in"));
  elements.zoomReadout.addEventListener("click", () => viewport.applyZoomCommand("reset"));
  elements.zoomFit.addEventListener("click", () => viewport.applyZoomCommand("fit_width"));
  bindViewportInput();
  elements.source.addEventListener("input", () => {
    draftGeneration += 1;
    sourceDirty = true;
    elements.source.dataset.dirty = "true";
    renderController?.updateWorkspace({ ...workspace, authority: "inert", preview: null });
    projectControls();
    setStatus("Editing source · leave the editor or press Ctrl+Enter to apply");
  });
  elements.source.addEventListener("blur", () => applyDraft());
  elements.source.addEventListener("keydown", (event) => {
    if (event.key === "Enter" && (event.ctrlKey || event.metaKey)) {
      event.preventDefault();
      applyDraft();
    }
  });
  elements.deckRail.addEventListener("keydown", (event) => {
    if (event.key !== "ArrowUp" && event.key !== "ArrowDown") return;
    event.preventDefault();
    enqueue(requestViewCommand(event.key === "ArrowUp" ? "previous_slide" : "next_slide"));
  });
  document.addEventListener("keydown", (event) => {
    if (isTextEntry(event.target)) return;
    if (event.code === "Space") {
      event.preventDefault();
      viewport.setSpaceHeld(true);
      return;
    }
    if (!(event.ctrlKey || event.metaKey) || event.altKey) return;
    if (event.key === "=" || event.key === "+") {
      event.preventDefault();
      viewport.applyZoomCommand("in");
      return;
    }
    if (event.key === "-") {
      event.preventDefault();
      viewport.applyZoomCommand("out");
      return;
    }
    if (event.key === "0") {
      event.preventDefault();
      viewport.applyZoomCommand("reset");
      return;
    }
    const key = event.key.toLowerCase();
    const command = key === "z" ? (event.shiftKey ? "redo" : "undo") : key === "y" ? "redo" : null;
    if (command === null) return;
    event.preventDefault();
    sendHistory(command);
  });
  document.addEventListener("keyup", (event) => {
    if (event.code !== "Space") return;
    viewport.setSpaceHeld(false);
  });
  window.addEventListener("blur", () => viewport.setSpaceHeld(false));
}

function isTextEntry(target) {
  return target instanceof HTMLInputElement || target instanceof HTMLTextAreaElement || target?.isContentEditable;
}

function bindViewportInput() {
  elements.deck.addEventListener("wheel", (event) => {
    event.preventDefault();
    if (event.ctrlKey || event.metaKey) viewport.zoomByWheel(event);
    else viewport.panByWheel(event);
  }, { passive: false });

  elements.deck.addEventListener("pointerdown", (event) => {
    if (!viewport.beginPan(event)) return;
    event.preventDefault();
    event.stopPropagation();
  }, true);

  elements.deck.addEventListener("pointermove", (event) => {
    if (viewport.continuePan(event)) event.preventDefault();
  }, true);

  const finish = (event) => {
    if (viewport.endPan(event.pointerId)) event.preventDefault?.();
  };
  elements.deck.addEventListener("pointerup", finish, true);
  elements.deck.addEventListener("pointercancel", finish, true);
  elements.deck.addEventListener("lostpointercapture", finish, true);
}

function executeHostAction(action) {
  renderController?.executeAction(action);
}

function activeDeckSlide() {
  return elements.deckCanvas.querySelector(".deck-row.is-current .deck-slide")
    ?? elements.deckCanvas.querySelector(".deck-slide");
}

function addSlide() {
  if (workspace !== null && !sourceDirty) enqueue(requestNewSlide(workspace.source.revision));
}

function sendHistory(command) {
  if (workspace !== null && !sourceDirty) enqueue(requestHistory(command, workspace.source.revision));
}

function applyDraft() {
  if (!sourceDirty || workspace === null) return;
  enqueue(requestReplaceSource(
    workspace.source.revision,
    base16FromBytes(encoder.encode(elements.source.value)),
  ));
}

function enqueue(request, context = {}) {
  transport = transport
    .then(() => dispatchAndApply(request, context))
    .catch((failure) => showFailure(failure, "Couldn’t update the presentation"));
  return transport;
}

async function dispatchAndApply(request, context = {}) {
  const draftFence = captureDraftFence();
  const response = await dispatch(request);
  if (!response.ok) throw new ProductV2RejectedError(response);
  await applyResponse(request, response, { ...context, draftFence });
  return response;
}

async function dispatch(request) {
  const gate = testDispatchGate;
  if (gate !== null && !gate.claimed) {
    gate.claimed = true;
    await gate.promise;
  }
  const raw = await reactor.productV2Dispatch(JSON.stringify(request));
  const response = decodeProductV2Response(raw);
  const trace = redactProtocolExchange(request, response);
  protocolTrace.push(trace);
  if (protocolTrace.length > 300) protocolTrace.shift();
  elements.output.textContent = JSON.stringify(trace, null, 2);
  return response;
}

async function applyResponse(request, response, context) {
  const draftIsCurrent = currentDraftMatches(context.draftFence);
  if (draftIsCurrent) {
    for (const action of response.actions) executeHostAction(action);
  }
  workspace = response.workspace;
  const adoptsSource = new Set([
    "replace_source", "undo", "redo", "new_slide", "pointer_event",
  ]).has(request.command) || context.explicitSourceLoad === true;
  if (draftIsCurrent && (!sourceDirty || adoptsSource)) {
    adoptHaskellSource(workspace.source.base16);
    if (request.command === "replace_source" || context.explicitSourceLoad === true) {
      sourceDirty = false;
      delete elements.source.dataset.dirty;
    }
  }
  if (!draftIsCurrent) {
    renderWorkspace();
    setStatus("Newer source changes are waiting to be applied");
    return;
  }

  const repaintRequested = response.actions.some((action) => action.kind === "repaint");
  if (workspace.renderOffer !== null) {
    if (!repaintRequested && !new Set(["open_source", "undo", "redo", "replace_source", "select_slide", "new_slide"]).has(request.command)) {
      throw new ProductV2WireError("render offer arrived without a repaint effect");
    }
    mountRender(workspace.renderOffer);
    const acknowledgementFence = captureDraftFence();
    const acknowledged = await dispatch(requestAcknowledgePaint(workspace.renderOffer.fence));
    if (!acknowledged.ok) throw new ProductV2RejectedError(acknowledged);
    if (currentDraftMatches(acknowledgementFence)) {
      for (const action of acknowledged.actions) executeHostAction(action);
    }
    workspace = acknowledged.workspace;
    renderWorkspace();
    if (!currentDraftMatches(acknowledgementFence)) {
      setStatus("Newer source changes are waiting to be applied");
      return;
    }
  } else {
    if (workspace.displayedRender !== null && !sameRenderFence(renderController?.fence, workspace.displayedRender.fence)) {
      mountRender(workspace.displayedRender);
    }
    renderWorkspace();
  }
  setStatus(statusFor(response));
}

function sameRenderFence(left, right) {
  return left !== undefined && left !== null
    && left.session === right.session
    && left.revision === right.revision
    && left.ticket === right.ticket
    && left.surface.frame === right.surface.frame
    && left.surface.kind === right.surface.kind;
}

function mountRender(correlated) {
  const next = createProductV2RenderSurface(correlated, {
    selection: workspace?.selection ?? null,
    onPointerEvent(event) { return enqueue(requestPointerEvent(event)); },
    onNodeActivation(surface, nodeId) { enqueue(requestActivateNode(surface, nodeId)); },
  });
  renderController?.deactivate();
  renderController = next;
  deckStructureKey = null;
}

function renderWorkspace() {
  if (workspace === null) return;
  renderController?.updateWorkspace(sourceDirty
    ? { ...workspace, authority: "inert", preview: null }
    : workspace);
  projectDeck();
  projectViewport();
  projectControls();
}

function projectViewport() {
  const state = viewport.state();
  elements.zoomReadout.textContent = `${Math.round(state.zoom * 100)}%`;
  elements.zoomOut.disabled = !state.canZoomOut;
  elements.zoomIn.disabled = !state.canZoomIn;
  elements.zoomReadout.disabled = !state.canReset;
  elements.zoomFit.disabled = false;
}

function projectDeck() {
  const navigator = workspace.navigator;
  const planKeys = navigator.items.map((item) => [
    item.frame,
    item.audience?.revision ?? null,
    item.audience?.ticket ?? null,
    item.notes?.revision ?? null,
    item.notes?.ticket ?? null,
  ]);
  const controllerKey = renderController === null ? null : [
    renderController.fence.revision,
    renderController.fence.ticket,
    renderController.fence.surface.frame,
  ];
  const nextKey = JSON.stringify([navigator.activeFrame, planKeys, controllerKey]);
  if (nextKey === deckStructureKey) {
    updateActiveMarkers(navigator.activeFrame);
    syncViewportToDeck(navigator.activeFrame);
    return;
  }
  deckStructureKey = nextKey;
  const thumbNodes: HTMLElement[] = [];
  const rows: HTMLElement[] = [];
  navigator.items.forEach((item, index) => {
    const thumb = document.createElement("button");
    thumb.type = "button";
    thumb.className = "slide-thumb";
    thumb.dataset.frame = item.frame;
    thumb.setAttribute("aria-label", `Slide ${index + 1}: ${item.title || "Untitled"}`);
    const number = document.createElement("span");
    number.className = "slide-thumb-number";
    number.textContent = String(index + 1);
    const thumbCard = document.createElement("span");
    thumbCard.className = "thumb-card";
    if (item.audience !== null) thumbCard.append(createProductV2StaticSurface(item.audience));
    thumb.append(number, thumbCard);
    thumb.addEventListener("click", () => enqueue(requestSelectSlide(item.frame)));
    thumbNodes.push(thumb);

    const row = document.createElement("article");
    row.className = "deck-row";
    row.dataset.frame = item.frame;
    row.setAttribute("aria-label", item.title || `Slide ${index + 1}`);
    const slide = document.createElement("div");
    slide.className = "deck-slide";
    slide.dataset.frame = item.frame;
    const isActiveController = item.frame === navigator.activeFrame
      && renderController?.fence.surface.frame === item.frame;
    if (isActiveController) slide.append(renderController.element);
    else if (item.audience !== null) slide.append(createProductV2StaticSurface(item.audience));
    const notes = document.createElement("aside");
    notes.className = "deck-note";
    notes.setAttribute("aria-label", `Notes for ${item.title || `slide ${index + 1}`}`);
    if (item.notes !== null) notes.append(createProductV2StaticSurface(item.notes));
    else {
      const empty = document.createElement("span");
      empty.className = "notes-empty";
      empty.textContent = "Notes";
      notes.append(empty);
    }
    row.append(slide, notes);
    if (item.frame !== navigator.activeFrame) {
      row.addEventListener("click", () => enqueue(requestSelectSlide(item.frame)), { once: true });
    }
    rows.push(row);
  });
  elements.thumbs.replaceChildren(...thumbNodes);
  elements.deckCanvas.replaceChildren(...rows);
  updateActiveMarkers(navigator.activeFrame);
  viewport.measure();
  syncViewportToDeck(navigator.activeFrame);
}

/**
 * Selection is Haskell-owned, but showing the selected slide is local
 * presentation, so a newly activated frame is revealed without disturbing the
 * zoom the reader chose.
 */
function syncViewportToDeck(activeFrame) {
  if (activeFrame === activeFrameKey) return;
  activeFrameKey = activeFrame;
  viewport.revealActiveSlide();
}

function updateActiveMarkers(activeFrame) {
  for (const thumb of elements.thumbs.querySelectorAll<HTMLElement>(".slide-thumb")) {
    const active = thumb.dataset.frame === activeFrame;
    thumb.classList.toggle("is-current", active);
    if (active) thumb.setAttribute("aria-current", "true");
    else thumb.removeAttribute("aria-current");
  }
  for (const row of elements.deckCanvas.querySelectorAll<HTMLElement>(".deck-row")) {
    row.classList.toggle("is-current", row.dataset.frame === activeFrame);
  }
}

function projectControls() {
  if (workspace === null) return setControlsUnavailable();
  elements.undo.disabled = sourceDirty || !workspace.canUndo;
  elements.redo.disabled = sourceDirty || !workspace.canRedo;
  elements.newSlide.disabled = sourceDirty || !workspace.navigator.newSlide.enabled;
  elements.deckAdd.disabled = elements.newSlide.disabled;
  elements.source.disabled = false;
}

function setControlsUnavailable() {
  for (const element of [
    elements.undo, elements.redo, elements.newSlide, elements.deckAdd,
    elements.zoomIn, elements.zoomOut, elements.zoomReadout, elements.zoomFit,
  ]) element.disabled = true;
  elements.source.disabled = true;
}

function adoptHaskellSource(base16) {
  const bytes = bytesFromBase16(base16);
  try {
    elements.source.value = strictDecoder.decode(bytes);
  } catch {
    elements.source.value = "";
    elements.source.disabled = true;
  }
}

function captureDraftFence() {
  return Object.freeze({ generation: draftGeneration, text: elements.source.value });
}

function currentDraftMatches(fence) {
  return fence.generation === draftGeneration && fence.text === elements.source.value;
}

function statusFor(response) {
  if (response.kind === "pointer_committed") return "Moved node · Undo is available";
  if (response.kind === "slide_created") return "New slide added";
  if (response.kind === "undo") return "Undone";
  if (response.kind === "redo") return "Redone";
  if (response.kind === "source_replaced") return "Source applied";
  return "Scroll through slides · click a node to select · drag to move";
}

function setStatus(message) { elements.status.textContent = message; }

export function readProductV2TestState() {
  requireProductV2TestMode();
  return structuredClone({
    workspace,
    trace: protocolTrace,
    draft: { generation: draftGeneration, text: elements.source.value, dirty: sourceDirty },
    dispatchHeld: testDispatchGate?.claimed === true,
    viewport: viewport.state(),
  });
}

export function holdNextProductV2DispatchForTest() {
  requireProductV2TestMode();
  if (testDispatchGate !== null) throw new Error("A Product/2 test dispatch is already held");
  let release;
  const promise = new Promise((resolve) => { release = resolve; });
  testDispatchGate = { claimed: false, promise, release };
}

export function releaseProductV2DispatchForTest() {
  requireProductV2TestMode();
  const gate = testDispatchGate;
  if (gate === null) throw new Error("No Product/2 test dispatch is held");
  testDispatchGate = null;
  gate.release();
}

function requireProductV2TestMode() {
  if (new URLSearchParams(location.search).get("productV2Test") !== "1") {
    throw new Error("Product/2 in-memory test access is disabled");
  }
}

function showFailure(failure, message) {
  setStatus(message);
  if (failure instanceof ProductV2RejectedError) {
    elements.output.textContent = JSON.stringify({ kind: "error", errorCode: failure.response.error.code });
  } else {
    elements.output.textContent = JSON.stringify({
      kind: "host_failure",
      name: failure instanceof Error ? failure.name : "UnknownFailure",
    });
  }
}
