/**
 * Catalog-backed shape palette for the browser host.
 *
 * Haskell owns catalog identity, family grouping, search, stencil resolution,
 * and preview geometry. This module displays at most 300 already-resolved
 * results, asks the read-only search seam for successor projections, and emits
 * only revision-fenced `insert_shape` edit intents.
 */

import {
  clientPointToSlide,
  createInsertShapeIntent,
  createResolvedOutlineGroup,
  validateResolvedOutlineSet,
} from "./product-renderer.js";

const svgNamespace = "http://www.w3.org/2000/svg";
const catalogResultLimit = 300;
const defaultPageSize = 60;
const maximumFamilies = 512;
const maximumKeywords = 128;
const maximumTextLength = 16_384;
const dragThresholdPixels = 5;
const identifierPattern = /^[A-Za-z_][A-Za-z0-9_.-]*$/;

/**
 * A catalog search projection violated the browser seam.
 */
export class ShapePaletteProjectionError extends Error {
  constructor(message) {
    super(message);
    this.name = "ShapePaletteProjectionError";
  }
}

/**
 * Validate one Haskell-owned catalog search result projection.
 *
 * @param {unknown} value
 * @returns {Readonly<Record<string, unknown>>}
 */
export function validateShapeCatalogProjection(value) {
  const root = expectRecord(value, "catalog");
  requireExactKeys(
    root,
    ["families", "results", "query", "family"],
    "catalog",
  );
  const families = expectArray(
    root.families,
    "catalog.families",
    maximumFamilies,
  ).map((family, index) =>
    validateFamily(family, `catalog.families[${index}]`),
  );
  const familyIds = new Set();
  for (const family of families) {
    if (familyIds.has(family.id)) {
      throw new ShapePaletteProjectionError(
        `catalog.families contains duplicate id ${family.id}`,
      );
    }
    familyIds.add(family.id);
  }

  const selectedFamily =
    root.family === null
      ? null
      : expectText(root.family, "catalog.family");
  if (selectedFamily !== null && !familyIds.has(selectedFamily)) {
    throw new ShapePaletteProjectionError(
      "catalog.family does not identify a projected family",
    );
  }

  const results = expectArray(
    root.results,
    "catalog.results",
    catalogResultLimit,
  ).map((result, index) =>
    validateResult(result, `catalog.results[${index}]`),
  );
  const resultIds = new Set();
  for (const result of results) {
    if (resultIds.has(result.id)) {
      throw new ShapePaletteProjectionError(
        `catalog.results contains duplicate shape id ${result.id}`,
      );
    }
    if (!familyIds.has(result.family)) {
      throw new ShapePaletteProjectionError(
        `catalog result ${result.id} references unprojected family ${result.family}`,
      );
    }
    resultIds.add(result.id);
  }

  return deepFreeze({
    families,
    results,
    query: expectSearchText(root.query, "catalog.query"),
    family: selectedFamily,
  });
}

/**
 * Build a bounded, immutable search request. This is a read-only query seam,
 * not an EditIntent.
 *
 * @param {string} query
 * @param {string|null} family
 */
export function createShapeSearchRequest(query, family) {
  return deepFreeze({
    query: expectSearchText(query, "search.query"),
    family:
      family === null ? null : expectText(family, "search.family"),
    limit: catalogResultLimit,
  });
}

/**
 * Mount a controlled shape palette.
 *
 * `onSearchRequest` returns a successor catalog projection (or `undefined`
 * when the caller will call `updateCatalog` itself). Search requests are
 * correlated locally so a late response cannot replace newer results.
 *
 * @param {HTMLElement} container
 * @param {{
 *   revision: number,
 *   catalog: unknown,
 *   insertionSurface: HTMLElement,
 *   onIntent: (intent: Readonly<Record<string, unknown>>) => unknown,
 *   onSearchRequest: (
 *     request: Readonly<{query:string,family:string|null,limit:number}>
 *   ) => Promise<unknown>|unknown,
 *   onAttribution?: (
 *     value: Readonly<Record<string, unknown>>
 *   ) => unknown,
 *   pageSize?: number
 * }} options
 * @returns {{
 *   element: HTMLElement,
 *   updateRevision: (revision: number) => void,
 *   updateCatalog: (catalog: unknown) => void,
 *   searchRequest: () => Readonly<Record<string, unknown>>,
 *   search: () => Promise<void>,
 *   cancelGesture: () => void,
 *   destroy: () => void
 * }}
 */
export function mountShapePalette(container, options) {
  requireContainer(container, "Shape palette");
  if (typeof options?.onIntent !== "function") {
    throw new TypeError("Shape palette requires an onIntent callback");
  }
  if (typeof options?.onSearchRequest !== "function") {
    throw new TypeError("Shape palette requires an onSearchRequest callback");
  }
  if (
    options.insertionSurface === null ||
    typeof options.insertionSurface !== "object" ||
    typeof options.insertionSurface.getBoundingClientRect !== "function"
  ) {
    throw new TypeError("Shape palette requires an insertion surface");
  }
  if (
    options.onAttribution !== undefined &&
    typeof options.onAttribution !== "function"
  ) {
    throw new TypeError("Shape palette onAttribution must be a function");
  }

  const ownerDocument = container.ownerDocument;
  const root = ownerDocument.createElement("section");
  root.className = "sb-shape-palette";
  root.setAttribute("role", "region");
  root.setAttribute("aria-label", "Shape library");
  root.style.cssText =
    "box-sizing:border-box;height:100%;min-height:16rem;display:flex;" +
    "flex-direction:column;gap:.65rem;padding:.7rem;background:#f8fafc;" +
    "color:#172033;font:500 .82rem/1.25 system-ui,sans-serif";
  container.append(root);

  let revision = expectRevision(options.revision, "palette.revision");
  let catalog = validateShapeCatalogProjection(options.catalog);
  let visibleCount = boundedPageSize(options.pageSize);
  let gesture = null;
  let searchTimer = null;
  let searchGeneration = 0;
  let destroyed = false;

  const controls = ownerDocument.createElement("div");
  controls.className = "sb-shape-palette-controls";
  controls.style.cssText =
    "display:grid;grid-template-columns:minmax(0,1fr) minmax(7rem,.7fr);" +
    "gap:.45rem";
  const searchInput = ownerDocument.createElement("input");
  searchInput.type = "search";
  searchInput.className = "sb-shape-search";
  searchInput.setAttribute("aria-label", "Search shapes");
  searchInput.placeholder = "Search shapes";
  searchInput.style.cssText =
    "box-sizing:border-box;width:100%;min-width:0;border:1px solid #cbd5e1;" +
    "border-radius:.4rem;padding:.48rem .55rem;background:white;color:inherit";
  const familySelect = ownerDocument.createElement("select");
  familySelect.className = "sb-shape-family";
  familySelect.setAttribute("aria-label", "Shape family");
  familySelect.style.cssText =
    "box-sizing:border-box;width:100%;min-width:0;border:1px solid #cbd5e1;" +
    "border-radius:.4rem;padding:.45rem;background:white;color:inherit";
  controls.append(searchInput, familySelect);

  const status = ownerDocument.createElement("div");
  status.className = "sb-shape-palette-status";
  status.setAttribute("role", "status");
  status.setAttribute("aria-live", "polite");
  status.style.cssText = "min-height:1.2rem;color:#64748b;font-size:.76rem";

  const results = ownerDocument.createElement("div");
  results.className = "sb-shape-results";
  results.setAttribute("role", "list");
  results.style.cssText =
    "display:grid;grid-template-columns:repeat(auto-fill,minmax(6.4rem,1fr));" +
    "align-content:start;gap:.5rem;overflow:auto;padding:.08rem";

  const more = ownerDocument.createElement("button");
  more.type = "button";
  more.className = "sb-shape-more";
  more.textContent = "Show more";
  more.style.cssText =
    "align-self:center;border:1px solid #94a3b8;border-radius:.4rem;" +
    "padding:.45rem .75rem;background:white;color:inherit;cursor:pointer";
  more.addEventListener("click", () => {
    visibleCount = Math.min(
      catalog.results.length,
      visibleCount + boundedPageSize(options.pageSize),
    );
    renderResults();
  });

  root.append(controls, status, results, more);

  searchInput.addEventListener("input", () => {
    scheduleSearch();
  });
  familySelect.addEventListener("change", () => {
    void requestSearch();
  });
  renderCatalog();

  function renderCatalog() {
    searchInput.value = catalog.query;
    familySelect.replaceChildren();
    const allFamilies = ownerDocument.createElement("option");
    allFamilies.value = "";
    allFamilies.textContent = "All families";
    familySelect.append(allFamilies);
    for (const family of catalog.families) {
      const option = ownerDocument.createElement("option");
      option.value = family.id;
      option.textContent = `${family.label} (${family.count})`;
      familySelect.append(option);
    }
    familySelect.value = catalog.family ?? "";
    visibleCount = Math.min(
      catalog.results.length,
      boundedPageSize(options.pageSize),
    );
    renderResults();
  }

  function renderResults() {
    cancelGesture();
    results.replaceChildren();
    const visible = catalog.results.slice(0, visibleCount);
    for (const result of visible) {
      results.append(createResultCard(result));
    }
    more.hidden = visibleCount >= catalog.results.length;
    status.textContent =
      catalog.results.length === 0
        ? "No matching shapes"
        : `Showing ${visible.length} of ${catalog.results.length} resolved shapes`;
  }

  function createResultCard(result) {
    const card = ownerDocument.createElement("article");
    card.className = "sb-shape-card";
    card.dataset.shapeId = result.id;
    card.setAttribute("role", "listitem");
    card.style.cssText =
      "min-width:0;display:flex;flex-direction:column;border:1px solid #d8e0ea;" +
      "border-radius:.5rem;background:white;overflow:hidden";

    const insert = ownerDocument.createElement("button");
    insert.type = "button";
    insert.className = "sb-shape-insert";
    insert.dataset.shapeId = result.id;
    insert.setAttribute("aria-label", `Insert ${result.label}`);
    insert.title = `${result.label} — ${result.category}`;
    insert.style.cssText =
      "min-width:0;display:grid;grid-template-rows:4.3rem auto;gap:.28rem;" +
      "border:0;padding:.42rem;background:white;color:inherit;cursor:grab;" +
      "touch-action:none";

    const preview = createPreview(result);
    const label = ownerDocument.createElement("span");
    label.textContent = result.label;
    label.style.cssText =
      "overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:.74rem";
    insert.append(preview, label);
    bindInsertionGesture(insert, result);
    card.append(insert);

    if (result.attribution !== null) {
      const attribution = ownerDocument.createElement("button");
      attribution.type = "button";
      attribution.className = "sb-shape-attribution";
      attribution.textContent = "Attribution";
      attribution.setAttribute(
        "aria-label",
        `Show attribution for ${result.label}`,
      );
      attribution.style.cssText =
        "border:0;border-top:1px solid #e2e8f0;padding:.25rem .4rem;" +
        "background:#f8fafc;color:#475569;font-size:.68rem;cursor:pointer";
      attribution.addEventListener("click", () => {
        options.onAttribution?.(
          deepFreeze({
            shapeId: result.id,
            attribution: result.attribution,
          }),
        );
      });
      card.append(attribution);
    }
    return card;
  }

  function createPreview(result) {
    const svg = ownerDocument.createElementNS(svgNamespace, "svg");
    svg.classList.add("sb-shape-preview");
    const margin = Math.max(result.box.width, result.box.height) * 0.12;
    const left = result.box.x - result.box.width / 2 - margin;
    const bottom = result.box.y - result.box.height / 2 - margin;
    const width = result.box.width + 2 * margin;
    const height = result.box.height + 2 * margin;
    svg.setAttribute(
      "viewBox",
      `${svgNumber(left)} ${svgNumber(bottom)} ${svgNumber(width)} ${svgNumber(height)}`,
    );
    svg.setAttribute("preserveAspectRatio", "xMidYMid meet");
    svg.setAttribute("aria-hidden", "true");
    svg.setAttribute("focusable", "false");
    svg.style.cssText = "display:block;width:100%;height:100%;overflow:visible";

    const yUp = ownerDocument.createElementNS(svgNamespace, "g");
    yUp.setAttribute(
      "transform",
      `translate(0 ${svgNumber(2 * result.box.y)}) scale(1 -1)`,
    );
    yUp.append(
      createResolvedOutlineGroup(
        ownerDocument,
        result.outlines,
        result.style,
      ),
    );
    svg.append(yUp);
    return svg;
  }

  function bindInsertionGesture(target, result) {
    let suppressClick = false;

    target.addEventListener("pointerdown", (event) => {
      if (
        destroyed ||
        gesture !== null ||
        !event.isPrimary ||
        event.button !== 0
      ) {
        return;
      }
      const ghost = target.cloneNode(true);
      ghost.disabled = true;
      ghost.removeAttribute("aria-label");
      ghost.setAttribute("aria-hidden", "true");
      ghost.classList.add("sb-shape-drag-ghost");
      ghost.style.cssText =
        "position:fixed;z-index:2147483647;width:7rem;height:5.5rem;" +
        "pointer-events:none;opacity:.72;transform:translate(-50%,-50%);" +
        "border:1px solid #64748b;border-radius:.5rem;background:white";
      ownerDocument.body.append(ghost);
      gesture = {
        pointerId: event.pointerId,
        target,
        result,
        ghost,
        startX: event.clientX,
        startY: event.clientY,
        dragged: false,
      };
      positionGhost(event.clientX, event.clientY);
      target.dataset.dragging = "true";
      try {
        target.setPointerCapture(event.pointerId);
      } catch {
        // Synthetic tests can dispatch without an active browser pointer.
      }
      event.preventDefault();
    });

    target.addEventListener("pointermove", (event) => {
      if (gesture?.pointerId !== event.pointerId) {
        return;
      }
      if (
        !gesture.dragged &&
        Math.hypot(
          event.clientX - gesture.startX,
          event.clientY - gesture.startY,
        ) >= dragThresholdPixels
      ) {
        gesture.dragged = true;
        target.style.cursor = "grabbing";
      }
      positionGhost(event.clientX, event.clientY);
      event.preventDefault();
    });

    target.addEventListener("pointerup", (event) => {
      if (gesture?.pointerId !== event.pointerId) {
        return;
      }
      const completed = gesture;
      const dragged = completed.dragged;
      cancelGesture();
      if (!dragged || destroyed) {
        return;
      }
      suppressClick = true;
      const point = clientPointToSlide(
        event.clientX,
        event.clientY,
        options.insertionSurface.getBoundingClientRect(),
      );
      if (point !== null) {
        options.onIntent(
          createInsertShapeIntent(revision, completed.result.id, point),
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
    target.addEventListener("click", () => {
      if (suppressClick) {
        suppressClick = false;
        return;
      }
      if (!destroyed) {
        options.onIntent(
          createInsertShapeIntent(revision, result.id, {
            x: "8",
            y: "4.5",
          }),
        );
      }
    });
  }

  function positionGhost(clientX, clientY) {
    if (gesture === null) {
      return;
    }
    gesture.ghost.style.left = `${clientX}px`;
    gesture.ghost.style.top = `${clientY}px`;
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

  function scheduleSearch() {
    if (searchTimer !== null) {
      clearTimeout(searchTimer);
    }
    searchTimer = setTimeout(() => {
      searchTimer = null;
      void requestSearch();
    }, 120);
  }

  async function requestSearch() {
    if (destroyed) {
      return;
    }
    if (searchTimer !== null) {
      clearTimeout(searchTimer);
      searchTimer = null;
    }
    const request = currentSearchRequest();
    const generation = ++searchGeneration;
    root.setAttribute("aria-busy", "true");
    status.textContent = "Searching the Haskell shape catalog";
    try {
      const successor = await options.onSearchRequest(request);
      if (destroyed || generation !== searchGeneration) {
        return;
      }
      if (successor !== undefined) {
        updateCatalog(successor);
      }
    } catch (failure) {
      if (!destroyed && generation === searchGeneration) {
        root.dataset.searchError = "true";
        status.textContent =
          failure instanceof Error && failure.message.length > 0
            ? `Shape search failed: ${failure.message}`
            : "Shape search failed";
      }
    } finally {
      if (!destroyed && generation === searchGeneration) {
        root.removeAttribute("aria-busy");
      }
    }
  }

  function currentSearchRequest() {
    return createShapeSearchRequest(
      searchInput.value,
      familySelect.value === "" ? null : familySelect.value,
    );
  }

  function updateCatalog(nextCatalog) {
    if (destroyed) {
      throw new Error("Cannot update a destroyed shape palette");
    }
    catalog = validateShapeCatalogProjection(nextCatalog);
    delete root.dataset.searchError;
    renderCatalog();
  }

  function updateRevision(nextRevision) {
    if (destroyed) {
      throw new Error("Cannot update a destroyed shape palette");
    }
    revision = expectRevision(nextRevision, "palette.revision");
  }

  function destroy() {
    if (destroyed) {
      return;
    }
    destroyed = true;
    searchGeneration += 1;
    if (searchTimer !== null) {
      clearTimeout(searchTimer);
      searchTimer = null;
    }
    cancelGesture();
    root.remove();
  }

  return Object.freeze({
    element: root,
    updateRevision,
    updateCatalog,
    searchRequest: currentSearchRequest,
    search: requestSearch,
    cancelGesture,
    destroy,
  });
}

function validateFamily(value, path) {
  const family = expectRecord(value, path);
  requireExactKeys(family, ["id", "label", "count"], path);
  return {
    id: expectText(family.id, `${path}.id`),
    label: expectText(family.label, `${path}.label`),
    count: expectCount(family.count, `${path}.count`),
  };
}

function validateResult(value, path) {
  const result = expectRecord(value, path);
  requireExactKeys(
    result,
    [
      "id",
      "label",
      "family",
      "category",
      "keywords",
      "box",
      "outlines",
      "style",
      "attribution",
    ],
    path,
  );
  const resolved = validateResolvedOutlineSet(
    result.outlines,
    result.style,
    path,
  );
  const keywords = expectArray(
    result.keywords,
    `${path}.keywords`,
    maximumKeywords,
  ).map((keyword, index) =>
    expectText(keyword, `${path}.keywords[${index}]`),
  );
  return {
    id: expectIdentifier(result.id, `${path}.id`),
    label: expectText(result.label, `${path}.label`),
    family: expectText(result.family, `${path}.family`),
    category: expectText(result.category, `${path}.category`),
    keywords,
    box: validateBox(result.box, `${path}.box`),
    outlines: resolved.outlines,
    style: resolved.style,
    attribution:
      result.attribution === null
        ? null
        : validateAttribution(result.attribution, `${path}.attribution`),
  };
}

function validateAttribution(value, path) {
  const attribution = expectRecord(value, path);
  requireExactKeys(
    attribution,
    ["title", "author", "license", "source"],
    path,
  );
  return {
    title: expectText(attribution.title, `${path}.title`),
    author: expectText(attribution.author, `${path}.author`),
    license: expectText(attribution.license, `${path}.license`),
    source: expectText(attribution.source, `${path}.source`),
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

function boundedPageSize(value) {
  if (value === undefined) {
    return defaultPageSize;
  }
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new TypeError("Shape palette pageSize must be a positive integer");
  }
  return Math.min(value, catalogResultLimit);
}

function expectRecord(value, path) {
  if (
    value === null ||
    typeof value !== "object" ||
    Array.isArray(value) ||
    Object.getPrototypeOf(value) !== Object.prototype
  ) {
    throw new ShapePaletteProjectionError(`${path} must be a plain record`);
  }
  return value;
}

function expectArray(value, path, maximum) {
  if (!Array.isArray(value)) {
    throw new ShapePaletteProjectionError(`${path} must be an array`);
  }
  if (value.length > maximum) {
    throw new ShapePaletteProjectionError(
      `${path} exceeds its ${maximum}-entry limit`,
    );
  }
  return value;
}

function expectRevision(value, path) {
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new ShapePaletteProjectionError(
      `${path} must be a non-negative safe integer`,
    );
  }
  return value;
}

function expectCount(value, path) {
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new ShapePaletteProjectionError(
      `${path} must be a non-negative safe integer`,
    );
  }
  return value;
}

function expectFiniteNumber(value, path) {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new ShapePaletteProjectionError(`${path} must be a finite number`);
  }
  return value;
}

function expectPositiveNumber(value, path) {
  const number = expectFiniteNumber(value, path);
  if (number <= 0) {
    throw new ShapePaletteProjectionError(`${path} must be positive`);
  }
  return number;
}

function expectText(value, path) {
  if (
    typeof value !== "string" ||
    value.trim().length === 0 ||
    value.length > maximumTextLength ||
    /[\u0000-\u001f\u007f]/u.test(value)
  ) {
    throw new ShapePaletteProjectionError(
      `${path} must be non-empty text without controls`,
    );
  }
  return value;
}

function expectSearchText(value, path) {
  if (
    typeof value !== "string" ||
    value.length > maximumTextLength ||
    /[\u0000-\u001f\u007f]/u.test(value)
  ) {
    throw new ShapePaletteProjectionError(
      `${path} must be search text without controls`,
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
    throw new ShapePaletteProjectionError(`${path} must be a valid identifier`);
  }
  return value;
}

function requireExactKeys(record, expected, path) {
  const expectedSet = new Set(expected);
  for (const key of Object.keys(record)) {
    if (!expectedSet.has(key)) {
      throw new ShapePaletteProjectionError(`${path}.${key} is not supported`);
    }
  }
  for (const key of expected) {
    if (!Object.hasOwn(record, key)) {
      throw new ShapePaletteProjectionError(`${path}.${key} is required`);
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

function svgNumber(value) {
  const rounded = Math.round(value * 10 ** 9) / 10 ** 9;
  if (Object.is(rounded, -0) || rounded === 0) {
    return "0";
  }
  return rounded.toFixed(9).replace(/(?:\.0+|(\.\d+?)0+)$/, "$1");
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
