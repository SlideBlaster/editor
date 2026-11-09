const paneNames = new Set(["source", "shapes"]);
const preferencePrefix = "sb.view.";

/**
 * Read one best-effort workspace-pane preference.
 *
 * Storage absence, private-mode failures, and malformed values all preserve the
 * supplied fallback. Pane preferences are host presentation state and never
 * affect authored source.
 *
 * @param {"source" | "shapes"} name
 * @param {boolean} fallback
 * @returns {boolean}
 */
export function readPanePreference(name, fallback) {
  validateName(name);
  if (typeof fallback !== "boolean") {
    throw new TypeError("Pane preference fallback must be a boolean");
  }

  try {
    const stored = globalThis.localStorage.getItem(preferencePrefix + name);
    if (stored === "true") {
      return true;
    }
    if (stored === "false") {
      return false;
    }
  } catch {
    // The in-memory UI state still works when browser persistence is unavailable.
  }
  return fallback;
}

/**
 * Persist one workspace-pane preference when browser storage is available.
 *
 * @param {"source" | "shapes"} name
 * @param {boolean} visible
 * @returns {boolean} Whether the value was persisted.
 */
export function writePanePreference(name, visible) {
  validateName(name);
  if (typeof visible !== "boolean") {
    throw new TypeError("Pane preference value must be a boolean");
  }

  try {
    globalThis.localStorage.setItem(preferencePrefix + name, String(visible));
    return true;
  } catch {
    return false;
  }
}

/**
 * @param {string} name
 */
function validateName(name) {
  if (!paneNames.has(name)) {
    throw new TypeError(`Unsupported workspace pane preference: ${name}`);
  }
}
