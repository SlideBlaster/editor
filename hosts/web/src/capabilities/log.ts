import { CapabilityError } from "./error.ts";

const logMethods = Object.freeze({
  debug: "debug",
  info: "info",
  warn: "warn",
  error: "error",
});

/**
 * Write one structured message to the browser console.
 *
 * @param {unknown} payload
 * @returns {Promise<{written: true}>}
 */
export async function writeLog(payload) {
  if (
    typeof payload !== "object" ||
    payload === null ||
    typeof payload.level !== "string" ||
    typeof payload.message !== "string"
  ) {
    throw new CapabilityError(
      "invalid_payload",
      "log.write requires level and message strings",
    );
  }

  const method = logMethods[payload.level];
  if (method === undefined) {
    throw new CapabilityError(
      "invalid_log_level",
      `Unsupported log level: ${payload.level}`,
    );
  }

  globalThis.console[method]("[SlideBlaster Wasm]", payload.message, payload.context);
  return { written: true };
}
