import { CapabilityError } from "./error.ts";

const storagePrefix = "slideblaster2.workspace.";

/**
 * List workspace-relative text paths held by the browser workspace.
 *
 * @returns {Promise<{paths: string[]}>}
 */
export async function listPaths() {
  const paths: string[] = [];
  for (let index = 0; index < globalThis.localStorage.length; index += 1) {
    const key = globalThis.localStorage.key(index);
    if (key !== null && key.startsWith(storagePrefix)) {
      paths.push(key.slice(storagePrefix.length));
    }
  }
  paths.sort();
  return { paths };
}

/**
 * Read UTF-8-compatible authored text from the browser workspace.
 *
 * @param {unknown} payload
 * @returns {Promise<{text: string | null}>}
 */
export async function readText(payload) {
  const path = validatePath(payload);
  return { text: globalThis.localStorage.getItem(storagePrefix + path) };
}

/**
 * Write authored text to the browser workspace.
 *
 * @param {unknown} payload
 * @returns {Promise<{stored: true}>}
 */
export async function writeText(payload) {
  const path = validatePath(payload);
  if (
    typeof payload !== "object" ||
    payload === null ||
    typeof payload.text !== "string"
  ) {
    throw new CapabilityError(
      "invalid_payload",
      "storage.writeText requires a text string",
    );
  }

  globalThis.localStorage.setItem(storagePrefix + path, payload.text);
  return { stored: true };
}

/**
 * @param {unknown} payload
 * @returns {string}
 */
function validatePath(payload) {
  if (
    typeof payload !== "object" ||
    payload === null ||
    typeof payload.path !== "string"
  ) {
    throw new CapabilityError(
      "invalid_payload",
      "Storage operations require a path string",
    );
  }

  const path = payload.path;
  const segments = path.split("/");
  if (
    path.length === 0 ||
    path.length > 240 ||
    path.startsWith("/") ||
    path.includes("\\") ||
    segments.some((segment) => segment.length === 0 || segment === "." || segment === "..")
  ) {
    throw new CapabilityError(
      "invalid_storage_path",
      "Storage paths must be non-empty, relative, and normalized",
    );
  }

  return path;
}
