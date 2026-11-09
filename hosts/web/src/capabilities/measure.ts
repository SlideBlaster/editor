import { CapabilityError } from "./error.ts";

/**
 * Measure text using an isolated, non-visible DOM node.
 *
 * Measurements are derived layout evidence. They never mutate authored source.
 *
 * @param {unknown} payload
 * @returns {Promise<{width: number, height: number, lines: number}>}
 */
export async function measureText(payload) {
  if (
    typeof payload !== "object" ||
    payload === null ||
    typeof payload.text !== "string" ||
    typeof payload.font !== "string"
  ) {
    throw new CapabilityError(
      "invalid_payload",
      "measure.text requires text and font strings",
    );
  }

  const maxWidth = validateMaxWidth(payload.maxWidth);
  const node = document.createElement("div");
  node.textContent = payload.text.length === 0 ? "\u200b" : payload.text;
  node.style.position = "fixed";
  node.style.inset = "0 auto auto -100000px";
  node.style.visibility = "hidden";
  node.style.pointerEvents = "none";
  node.style.whiteSpace = "pre-wrap";
  node.style.overflowWrap = "normal";
  node.style.font = payload.font;
  node.style.width = maxWidth === null ? "max-content" : `${maxWidth}px`;
  node.style.maxWidth = maxWidth === null ? "none" : `${maxWidth}px`;

  document.body.append(node);
  try {
    const rectangle = node.getBoundingClientRect();
    const computed = globalThis.getComputedStyle(node);
    const lineHeight = Number.parseFloat(computed.lineHeight);
    const fontSize = Number.parseFloat(computed.fontSize);
    const effectiveLineHeight =
      Number.isFinite(lineHeight) && lineHeight > 0 ? lineHeight : fontSize * 1.2;
    const lines = Math.max(1, Math.round(rectangle.height / effectiveLineHeight));

    return {
      width: rectangle.width,
      height: rectangle.height,
      lines,
    };
  } finally {
    node.remove();
  }
}

/**
 * @param {unknown} value
 * @returns {number | null}
 */
function validateMaxWidth(value) {
  if (value === null || value === undefined) {
    return null;
  }
  if (typeof value !== "number" || !Number.isFinite(value) || value <= 0) {
    throw new CapabilityError(
      "invalid_payload",
      "measure.text maxWidth must be a positive finite number or null",
    );
  }
  return value;
}
