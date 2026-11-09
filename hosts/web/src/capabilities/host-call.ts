import { CapabilityError } from "./error.ts";
import { writeLog } from "./log.ts";
import { measureText } from "./measure.ts";
import { listPaths, readText, writeText } from "./storage.ts";

export const hostVersion = 1;

const operations = Object.freeze({
  "log.write": writeLog,
  "measure.text": measureText,
  "storage.list": listPaths,
  "storage.read": readText,
  "storage.write": writeText,
});

/**
 * Install the one mutable bootstrap object consumed by the Haskell web adapter.
 */
export function installHostCall() {
  const host = Object.freeze({ call: hostCall });
  Object.defineProperty(globalThis, "slideblasterHost", {
    configurable: true,
    enumerable: false,
    value: host,
    writable: false,
  });
}

/**
 * Validate, dispatch, and encode one host capability request.
 *
 * The function always resolves to JSON. Browser exceptions are translated to a
 * structured error before they cross back into Haskell.
 *
 * @param {string} rawRequest
 * @returns {Promise<string>}
 */
async function hostCall(rawRequest) {
  let requestId = 0;
  try {
    if (typeof rawRequest !== "string") {
      throw new CapabilityError(
        "invalid_request",
        "The host call request must be a JSON string",
      );
    }

    const request = JSON.parse(rawRequest);
    validateRequest(request);
    requestId = request.id;

    const operation = operations[`${request.capability}.${request.operation}`];
    if (operation === undefined) {
      throw new CapabilityError(
        "unsupported_capability",
        `Unsupported host operation: ${request.capability}.${request.operation}`,
      );
    }

    const result = await operation(request.payload);
    return JSON.stringify({
      version: hostVersion,
      id: requestId,
      ok: true,
      payload: result,
    });
  } catch (failure) {
    const error = normalizeFailure(failure);
    return JSON.stringify({
      version: hostVersion,
      id: requestId,
      ok: false,
      error,
    });
  }
}

/**
 * @param {unknown} request
 */
function validateRequest(request) {
  if (typeof request !== "object" || request === null) {
    throw new CapabilityError(
      "invalid_request",
      "The host call request must be a JSON object",
    );
  }
  if (request.version !== hostVersion) {
    throw new CapabilityError(
      "unsupported_protocol",
      `Expected host protocol version ${hostVersion}`,
    );
  }
  const expectedFields = ["version", "id", "capability", "operation", "payload"];
  const actualFields = Object.keys(request);
  if (
    actualFields.length !== expectedFields.length ||
    !expectedFields.every((field) => Object.hasOwn(request, field))
  ) {
    throw new CapabilityError(
      "invalid_request",
      "The host call request contains missing or unknown fields",
    );
  }
  if (!Number.isSafeInteger(request.id) || request.id < 0) {
    throw new CapabilityError(
      "invalid_request",
      "The host call id must be a non-negative safe integer",
    );
  }
  for (const field of ["capability", "operation"]) {
    if (typeof request[field] !== "string" || request[field].length === 0) {
      throw new CapabilityError(
        "invalid_request",
        `The host call ${field} must be a non-empty string`,
      );
    }
  }
  if (!Object.hasOwn(request, "payload")) {
    throw new CapabilityError(
      "invalid_request",
      "The host call payload field is required",
    );
  }
}

/**
 * @param {unknown} failure
 * @returns {{code: string, message: string}}
 */
function normalizeFailure(failure) {
  if (failure instanceof CapabilityError) {
    return { code: failure.code, message: failure.message };
  }
  if (failure instanceof Error) {
    return { code: "browser_failure", message: failure.message };
  }
  return { code: "browser_failure", message: "Unknown browser capability failure" };
}
