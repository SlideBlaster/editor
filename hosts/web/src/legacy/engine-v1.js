/**
 * Closed decoder for the shared `slideblaster.engine/1` JSON boundary.
 *
 * This module validates transport structure only. It does not interpret TikZ,
 * infer presentation semantics, or manufacture source edits. Render plans
 * accepted here are branded so the DOM renderer cannot be called with an
 * unchecked object assembled elsewhere in JavaScript.
 */

export const engineProtocol = "slideblaster.engine/1";

const coordinateSpace = "slide_16x9_y_up";
const maximumPortableOffset = 2_147_483_647;
const validatedRenderPlans = new WeakSet();
const utf8Decoder = new TextDecoder("utf-8", { fatal: true });
const utf8Encoder = new TextEncoder();

const diagnosticCategories = new Set([
  "malformed",
  "unsupported",
  "ambiguous",
]);

const diagnosticCodes = new Set([
  "expected_node_statement",
  "expected_connector_statement",
  "expected_syntax_token",
  "invalid_node_identifier",
  "invalid_connector_identifier",
  "invalid_coordinate_token",
  "invalid_utf8_content",
  "nested_node_content_unsupported",
  "node_options_unsupported",
  "connector_options_unsupported",
  "connector_operation_unsupported",
  "connector_target_unsupported",
  "extra_construct_unsupported",
  "multiple_constructs_ambiguous",
  "source_span_domain_exceeded",
]);

const emptyDetailCodes = new Set([
  "malformed_json",
  "invalid_field",
  "source_locality_postcondition_failed",
  "local_postcondition_failed",
]);

/**
 * A response that is JSON but violates the closed engine schema.
 */
export class EngineWireError extends Error {
  constructor(message) {
    super(message);
    this.name = "EngineWireError";
  }
}

/**
 * A valid typed rejection returned by the Haskell engine.
 */
export class EngineRejectedError extends Error {
  constructor(response) {
    super(`${response.error.code}: ${response.error.message}`);
    this.name = "EngineRejectedError";
    this.code = response.error.code;
    this.response = response;
  }
}

/**
 * Parse and validate one raw engine response.
 *
 * @param {string} rawResponse
 * @returns {Readonly<Record<string, unknown>>}
 */
export function decodeEngineResponse(rawResponse) {
  if (typeof rawResponse !== "string") {
    throw new EngineWireError("Engine response must be a JSON string");
  }

  let response;
  try {
    response = JSON.parse(rawResponse);
  } catch {
    throw new EngineWireError("Engine response is not valid JSON");
  }
  return validateEngineResponse(response);
}

/**
 * Validate an already decoded response. Exported for dependency-free protocol
 * fixtures; application code normally uses `decodeEngineResponse`.
 *
 * @param {unknown} response
 * @returns {Readonly<Record<string, unknown>>}
 */
export function validateEngineResponse(response) {
  expectObject(response, "response");
  expectLiteral(response.protocol, engineProtocol, "response.protocol");
  expectBoolean(response.ok, "response.ok");

  if (response.ok) {
    validateSuccessResponse(response);
  } else {
    validateErrorResponse(response);
  }

  return deepFreeze(response);
}

/**
 * Throw unless a render plan came through this module's closed decoder.
 *
 * @param {unknown} plan
 */
export function requireValidatedRenderPlan(plan) {
  if (
    typeof plan !== "object" ||
    plan === null ||
    !validatedRenderPlans.has(plan)
  ) {
    throw new EngineWireError(
      "DOM rendering requires a validated engine render plan",
    );
  }
}

/**
 * Encode bytes as canonical lowercase base16.
 *
 * @param {Uint8Array} bytes
 * @returns {string}
 */
export function encodeBase16(bytes) {
  if (!(bytes instanceof Uint8Array)) {
    throw new EngineWireError("Base16 input must be a Uint8Array");
  }
  return Array.from(bytes, (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
}

/**
 * Decode canonical lowercase base16.
 *
 * @param {string} value
 * @returns {Uint8Array}
 */
export function decodeBase16(value) {
  expectBase16(value, "base16");
  const bytes = new Uint8Array(value.length / 2);
  for (let index = 0; index < bytes.length; index += 1) {
    bytes[index] = Number.parseInt(
      value.slice(index * 2, index * 2 + 2),
      16,
    );
  }
  return bytes;
}

/**
 * Build the existing exact source-snapshot wire value from browser text.
 *
 * @param {number} revision
 * @param {string} text
 * @returns {{revision: number, source: string, encoding: "base16"}}
 */
export function snapshotFromText(revision, text) {
  expectSafeUnsignedInteger(revision, "snapshot.revision");
  expectUnicodeString(text, "snapshot text");
  return {
    revision,
    source: encodeBase16(utf8Encoder.encode(text)),
    encoding: "base16",
  };
}

/**
 * Decode a validated source snapshot for the browser textarea.
 *
 * @param {unknown} snapshot
 * @returns {string}
 */
export function textFromSnapshot(snapshot) {
  validateSnapshot(snapshot, "snapshot");
  try {
    return utf8Decoder.decode(decodeBase16(snapshot.source));
  } catch {
    throw new EngineWireError(
      "Engine snapshot cannot be represented by the UTF-8 browser source pane",
    );
  }
}

function validateSuccessResponse(response) {
  expectString(response.response, "response.response");
  switch (response.response) {
    case "inspection":
      requireExactKeys(
        response,
        ["protocol", "ok", "response", "snapshot", "inspection"],
        "inspection response",
      );
      validateSnapshot(response.snapshot, "response.snapshot");
      validateInspection(
        response.inspection,
        response.snapshot,
        "response.inspection",
      );
      return;
    case "replacement":
      requireExactKeys(
        response,
        ["protocol", "ok", "response", "snapshot", "inspection", "edit"],
        "replacement response",
      );
      validateSnapshot(response.snapshot, "response.snapshot");
      validateInspection(
        response.inspection,
        response.snapshot,
        "response.inspection",
      );
      validateReplacementReceipt(
        response.edit,
        response.snapshot,
        "response.edit",
      );
      return;
    case "tikz_analysis":
      requireExactKeys(
        response,
        ["protocol", "ok", "response", "snapshot", "analysis"],
        "TikZ analysis response",
      );
      validateSnapshot(response.snapshot, "response.snapshot");
      validateAnalysis(
        response.analysis,
        response.snapshot.revision,
        true,
        "response.analysis",
      );
      return;
    case "tikz_move":
      requireExactKeys(
        response,
        ["protocol", "ok", "response", "snapshot", "move", "analysis"],
        "TikZ move response",
      );
      validateSnapshot(response.snapshot, "response.snapshot");
      validateMove(response.move, response.snapshot, "response.move");
      validateAnalysis(
        response.analysis,
        response.snapshot.revision,
        false,
        "response.analysis",
      );
      validateMovePlanRelationships(response.move, response.analysis.renderPlan);
      return;
    case "tikz_style":
      requireExactKeys(
        response,
        ["protocol", "ok", "response", "snapshot", "style", "analysis"],
        "TikZ style response",
      );
      validateSnapshot(response.snapshot, "response.snapshot");
      validateStyle(response.style, response.snapshot, "response.style");
      validateAnalysis(
        response.analysis,
        response.snapshot.revision,
        false,
        "response.analysis",
      );
      return;
    default:
      throw new EngineWireError(
        `response.response has unknown variant ${JSON.stringify(response.response)}`,
      );
  }
}

function validateErrorResponse(response) {
  requireExactKeys(
    response,
    ["protocol", "ok", "error"],
    "engine error response",
  );
  expectObject(response.error, "response.error");
  requireExactKeys(
    response.error,
    ["code", "message", "details"],
    "response.error",
  );
  expectString(response.error.code, "response.error.code");
  expectUnicodeString(response.error.message, "response.error.message");
  expectObject(response.error.details, "response.error.details");
  validateErrorDetails(
    response.error.code,
    response.error.details,
    "response.error.details",
  );
}

function validateErrorDetails(code, details, path) {
  if (emptyDetailCodes.has(code)) {
    requireExactKeys(details, [], path);
    return;
  }

  switch (code) {
    case "unsupported_protocol":
      requireExactKeys(details, ["actual"], path);
      expectString(details.actual, `${path}.actual`);
      return;
    case "unknown_command":
      requireExactKeys(details, ["command"], path);
      expectString(details.command, `${path}.command`);
      return;
    case "stale_revision":
      requireExactKeys(
        details,
        ["requestedRevision", "actualRevision"],
        path,
      );
      expectSafeUnsignedInteger(
        details.requestedRevision,
        `${path}.requestedRevision`,
      );
      expectSafeUnsignedInteger(
        details.actualRevision,
        `${path}.actualRevision`,
      );
      return;
    case "span_out_of_bounds":
      requireExactKeys(details, ["start", "end", "sourceBytes"], path);
      expectPortableOffset(details.start, `${path}.start`);
      expectPortableOffset(details.end, `${path}.end`);
      expectSafeUnsignedInteger(details.sourceBytes, `${path}.sourceBytes`);
      return;
    case "expected_bytes_mismatch":
      requireExactKeys(details, ["expectedBytes", "actualBytes"], path);
      expectSafeUnsignedInteger(details.expectedBytes, `${path}.expectedBytes`);
      expectSafeUnsignedInteger(details.actualBytes, `${path}.actualBytes`);
      return;
    case "revision_exhausted":
      requireExactKeys(details, ["revision"], path);
      expectSafeUnsignedInteger(details.revision, `${path}.revision`);
      return;
    case "tikz_semantics_unavailable":
      validateOptionalDiagnosticDetails(details, path);
      return;
    case "tikz_target_missing":
    case "tikz_target_ambiguous":
    case "tikz_projection_unsupported":
      validateOptionalNodeIdDetails(details, path);
      return;
    case "tikz_verification_failed":
      requireExactKeys(details, ["reason"], path);
      expectOneOf(
        details.reason,
        ["parse_or_elaboration_failed", "semantic_mismatch"],
        `${path}.reason`,
      );
      return;
    default:
      throw new EngineWireError(
        `response.error.code has unknown variant ${JSON.stringify(code)}`,
      );
  }
}

function validateOptionalDiagnosticDetails(details, path) {
  const keys = Object.keys(details);
  if (keys.length === 0) {
    return;
  }
  requireExactKeys(details, ["diagnostics"], path);
  validateDiagnostics(details.diagnostics, `${path}.diagnostics`);
}

function validateOptionalNodeIdDetails(details, path) {
  const keys = Object.keys(details);
  if (keys.length === 0) {
    return;
  }
  requireExactKeys(details, ["nodeId"], path);
  expectNodeId(details.nodeId, `${path}.nodeId`);
}

function validateSnapshot(snapshot, path) {
  expectObject(snapshot, path);
  requireExactKeys(snapshot, ["revision", "source", "encoding"], path);
  expectSafeUnsignedInteger(snapshot.revision, `${path}.revision`);
  expectBase16(snapshot.source, `${path}.source`);
  expectLiteral(snapshot.encoding, "base16", `${path}.encoding`);
}

function validateInspection(inspection, snapshot, path) {
  expectObject(inspection, path);
  requireExactKeys(
    inspection,
    ["revision", "bytes", "lines", "utf8", "fingerprint"],
    path,
  );
  expectSafeUnsignedInteger(inspection.revision, `${path}.revision`);
  expectSafeUnsignedInteger(inspection.bytes, `${path}.bytes`);
  expectSafeUnsignedInteger(inspection.lines, `${path}.lines`);
  expectBoolean(inspection.utf8, `${path}.utf8`);
  expectString(inspection.fingerprint, `${path}.fingerprint`);
  if (!/^fnv1a64:[0-9a-f]{16}$/.test(inspection.fingerprint)) {
    throw new EngineWireError(`${path}.fingerprint is not canonical FNV-1a`);
  }
  if (inspection.revision !== snapshot.revision) {
    throw new EngineWireError(`${path}.revision does not match the snapshot`);
  }
  if (inspection.bytes !== snapshot.source.length / 2) {
    throw new EngineWireError(`${path}.bytes does not match the snapshot`);
  }
}

function validateReplacementReceipt(receipt, snapshot, path) {
  expectObject(receipt, path);
  requireExactKeys(
    receipt,
    [
      "beforeRevision",
      "afterRevision",
      "start",
      "end",
      "removedBytes",
      "insertedBytes",
      "changed",
    ],
    path,
  );
  expectSafeUnsignedInteger(receipt.beforeRevision, `${path}.beforeRevision`);
  expectSafeUnsignedInteger(receipt.afterRevision, `${path}.afterRevision`);
  expectPortableOffset(receipt.start, `${path}.start`);
  expectPortableOffset(receipt.end, `${path}.end`);
  expectSafeUnsignedInteger(receipt.removedBytes, `${path}.removedBytes`);
  expectSafeUnsignedInteger(receipt.insertedBytes, `${path}.insertedBytes`);
  expectBoolean(receipt.changed, `${path}.changed`);
  if (receipt.start > receipt.end) {
    throw new EngineWireError(`${path} has a reversed source span`);
  }
  if (receipt.removedBytes !== receipt.end - receipt.start) {
    throw new EngineWireError(`${path}.removedBytes does not match its span`);
  }
  if (receipt.afterRevision !== snapshot.revision) {
    throw new EngineWireError(
      `${path}.afterRevision does not match the snapshot`,
    );
  }
  const expectedAfter = receipt.changed
    ? receipt.beforeRevision + 1
    : receipt.beforeRevision;
  if (
    !Number.isSafeInteger(expectedAfter) ||
    receipt.afterRevision !== expectedAfter
  ) {
    throw new EngineWireError(`${path} has an invalid revision transition`);
  }
}

function validateAnalysis(analysis, revision, allowSyntaxOnly, path) {
  expectObject(analysis, path);
  expectString(analysis.state, `${path}.state`);
  if (analysis.state === "ready") {
    requireExactKeys(analysis, ["state", "renderPlan"], path);
    validateRenderPlan(analysis.renderPlan, revision, `${path}.renderPlan`);
    return;
  }
  if (analysis.state === "syntax_only" && allowSyntaxOnly) {
    requireExactKeys(analysis, ["state", "diagnostics"], path);
    validateDiagnostics(analysis.diagnostics, `${path}.diagnostics`);
    return;
  }
  throw new EngineWireError(`${path}.state is not valid for this response`);
}

function validateDiagnostics(diagnostics, path) {
  if (!Array.isArray(diagnostics) || diagnostics.length === 0) {
    throw new EngineWireError(`${path} must be a non-empty array`);
  }
  diagnostics.forEach((diagnostic, index) => {
    const itemPath = `${path}[${index}]`;
    expectObject(diagnostic, itemPath);
    requireExactKeys(
      diagnostic,
      ["category", "code", "span", "message"],
      itemPath,
    );
    expectOneOf(
      diagnostic.category,
      diagnosticCategories,
      `${itemPath}.category`,
    );
    expectOneOf(diagnostic.code, diagnosticCodes, `${itemPath}.code`);
    validateOptionalSpan(diagnostic.span, `${itemPath}.span`);
    expectUnicodeString(diagnostic.message, `${itemPath}.message`);
  });
}

function validateOptionalSpan(span, path) {
  if (span === null) {
    return;
  }
  expectObject(span, path);
  requireExactKeys(span, ["start", "end"], path);
  expectPortableOffset(span.start, `${path}.start`);
  expectPortableOffset(span.end, `${path}.end`);
  if (span.start > span.end) {
    throw new EngineWireError(`${path} is reversed`);
  }
}

function validateRenderPlan(plan, revision, path) {
  expectObject(plan, path);
  requireExactKeys(
    plan,
    ["sourceRevision", "coordinateSpace", "node", "connector"],
    path,
  );
  expectSafeUnsignedInteger(plan.sourceRevision, `${path}.sourceRevision`);
  if (plan.sourceRevision !== revision) {
    throw new EngineWireError(
      `${path}.sourceRevision does not match the snapshot`,
    );
  }
  expectLiteral(plan.coordinateSpace, coordinateSpace, `${path}.coordinateSpace`);

  expectObject(plan.node, `${path}.node`);
  requireExactKeys(
    plan.node,
    ["kind", "id", "center", "content", "contentStatus", "runs", "issues"],
    `${path}.node`,
  );
  expectLiteral(plan.node.kind, "content_node", `${path}.node.kind`);
  expectNodeId(plan.node.id, `${path}.node.id`);
  validatePoint(plan.node.center, `${path}.node.center`);
  expectUnicodeString(plan.node.content, `${path}.node.content`);
  validateContentStatus(plan.node.contentStatus, `${path}.node.contentStatus`);
  validateContentRuns(plan.node.runs, `${path}.node.runs`);
  validateContentIssues(plan.node.issues, `${path}.node.issues`);

  expectObject(plan.connector, `${path}.connector`);
  requireExactKeys(
    plan.connector,
    ["kind", "start", "end"],
    `${path}.connector`,
  );
  expectLiteral(
    plan.connector.kind,
    "straight_connector",
    `${path}.connector.kind`,
  );
  validatePoint(plan.connector.start, `${path}.connector.start`);
  validatePoint(plan.connector.end, `${path}.connector.end`);
  if (!pointsEqual(plan.node.center, plan.connector.start)) {
    throw new EngineWireError(
      `${path}.connector.start does not equal the resolved node center`,
    );
  }
  validatedRenderPlans.add(plan);
}

// Closed vocabularies. The engine chooses these names; the host only checks that
// what arrived is one of them, so an unrecognised value fails loudly here rather
// than being silently ignored while drawing.
const runKinds = new Set(["plain", "math", "verbatim", "break", "opaque"]);
const runDialects = new Set(["tex", "html", "markdown"]);
const styleWeights = new Set(["normal", "bold"]);
const styleSlants = new Set(["upright", "italic"]);
const styleFamilies = new Set(["serif", "sans", "mono"]);
const styleVariants = new Set(["normal", "smallcaps"]);
const contentIssueKinds = new Set(["unresolvable_colour", "unexpanded_macro"]);

function validateContentStatus(status, path) {
  expectObject(status, path);
  expectOneOf(status.kind, ["understood", "opaque"], `${path}.kind`);
  if (status.kind === "opaque") {
    requireExactKeys(status, ["kind", "reason"], path);
    expectUnicodeString(status.reason, `${path}.reason`);
  } else {
    requireExactKeys(status, ["kind"], path);
  }
}

function validateContentRuns(runs, path) {
  if (!Array.isArray(runs)) {
    throw new EngineWireError(`${path} must be an array`);
  }
  runs.forEach((run, index) => {
    const runPath = `${path}[${index}]`;
    expectObject(run, runPath);
    requireExactKeys(
      run,
      ["kind", "text", "path", "dialect", "link", "style"],
      runPath,
    );
    expectOneOf(run.kind, runKinds, `${runPath}.kind`);
    expectUnicodeString(run.text, `${runPath}.text`);
    validateTreePath(run.path, `${runPath}.path`);
    if (run.dialect !== null) {
      expectObject(run.dialect, `${runPath}.dialect`);
      requireExactKeys(run.dialect, ["name"], `${runPath}.dialect`);
      expectOneOf(run.dialect.name, runDialects, `${runPath}.dialect.name`);
    }
    if (run.link !== null) {
      expectObject(run.link, `${runPath}.link`);
      requireExactKeys(run.link, ["target"], `${runPath}.link`);
      expectUnicodeString(run.link.target, `${runPath}.link.target`);
    }
    validateResolvedStyle(run.style, `${runPath}.style`);
  });
}

// A run's path is how an interaction on screen names the construct it came from,
// so it must be a real sequence of child indices, not merely array-shaped.
function validateTreePath(value, path) {
  if (!Array.isArray(value)) {
    throw new EngineWireError(`${path} must be an array`);
  }
  value.forEach((index, position) => {
    expectSafeUnsignedInteger(index, `${path}[${position}]`);
  });
}

function validateResolvedStyle(style, path) {
  expectObject(style, path);
  requireExactKeys(
    style,
    [
      "weight",
      "slant",
      "family",
      "variant",
      "underline",
      "strike",
      "highlight",
      "foreground",
      "background",
    ],
    path,
  );
  expectOneOf(style.weight, styleWeights, `${path}.weight`);
  expectOneOf(style.slant, styleSlants, `${path}.slant`);
  expectOneOf(style.family, styleFamilies, `${path}.family`);
  expectOneOf(style.variant, styleVariants, `${path}.variant`);
  expectBoolean(style.underline, `${path}.underline`);
  expectBoolean(style.strike, `${path}.strike`);
  expectBoolean(style.highlight, `${path}.highlight`);
  validateOptionalColour(style.foreground, `${path}.foreground`);
  validateOptionalColour(style.background, `${path}.background`);
}

// Null means the author did not state a colour, which is different from stating
// black: the theme resolves the former.
function validateOptionalColour(colour, path) {
  if (colour === null) {
    return;
  }
  expectObject(colour, path);
  requireExactKeys(colour, ["srgb"], path);
  expectSrgbHex(colour.srgb, `${path}.srgb`);
}

function expectSrgbHex(value, path) {
  expectString(value, path);
  if (!/^#[0-9a-f]{6}$/.test(value)) {
    throw new EngineWireError(`${path} must be a lowercase sRGB hex triplet`);
  }
}

function validateContentIssues(issues, path) {
  if (!Array.isArray(issues)) {
    throw new EngineWireError(`${path} must be an array`);
  }
  issues.forEach((issue, index) => {
    const issuePath = `${path}[${index}]`;
    expectObject(issue, issuePath);
    requireExactKeys(issue, ["kind", "path", "detail"], issuePath);
    expectOneOf(issue.kind, contentIssueKinds, `${issuePath}.kind`);
    validateTreePath(issue.path, `${issuePath}.path`);
    expectUnicodeString(issue.detail, `${issuePath}.detail`);
  });
}

// A style receipt says what happened to which node and at which revisions. It
// deliberately carries no content: the changed text arrives only as the exact
// successor snapshot, so there is one authority for it.
function validateStyle(style, snapshot, path) {
  expectObject(style, path);
  requireExactKeys(
    style,
    ["outcome", "beforeRevision", "afterRevision", "nodeId"],
    path,
  );
  expectOneOf(style.outcome, ["verified_change", "unchanged"], `${path}.outcome`);
  expectSafeUnsignedInteger(style.beforeRevision, `${path}.beforeRevision`);
  expectSafeUnsignedInteger(style.afterRevision, `${path}.afterRevision`);
  expectNodeId(style.nodeId, `${path}.nodeId`);
  if (style.afterRevision !== snapshot.revision) {
    throw new EngineWireError(`${path}.afterRevision does not match snapshot`);
  }
  const expectedAfter =
    style.outcome === "verified_change"
      ? style.beforeRevision + 1
      : style.beforeRevision;
  if (
    !Number.isSafeInteger(expectedAfter) ||
    style.afterRevision !== expectedAfter
  ) {
    throw new EngineWireError(
      `${path}.afterRevision disagrees with ${path}.outcome`,
    );
  }
}

function validateMove(move, snapshot, path) {
  expectObject(move, path);
  requireExactKeys(
    move,
    [
      "outcome",
      "beforeRevision",
      "afterRevision",
      "nodeId",
      "destination",
    ],
    path,
  );
  expectOneOf(
    move.outcome,
    ["verified_change", "unchanged"],
    `${path}.outcome`,
  );
  expectSafeUnsignedInteger(move.beforeRevision, `${path}.beforeRevision`);
  expectSafeUnsignedInteger(move.afterRevision, `${path}.afterRevision`);
  expectNodeId(move.nodeId, `${path}.nodeId`);
  validatePoint(move.destination, `${path}.destination`);
  if (move.afterRevision !== snapshot.revision) {
    throw new EngineWireError(`${path}.afterRevision does not match snapshot`);
  }
  const expectedAfter =
    move.outcome === "verified_change"
      ? move.beforeRevision + 1
      : move.beforeRevision;
  if (
    !Number.isSafeInteger(expectedAfter) ||
    move.afterRevision !== expectedAfter
  ) {
    throw new EngineWireError(`${path} has an invalid revision transition`);
  }
}

function validateMovePlanRelationships(move, plan) {
  if (move.nodeId !== plan.node.id) {
    throw new EngineWireError("Move target does not match the rendered node");
  }
  if (!pointsEqual(move.destination, plan.node.center)) {
    throw new EngineWireError(
      "Move destination does not match the rendered node center",
    );
  }
  if (!pointsEqual(move.destination, plan.connector.start)) {
    throw new EngineWireError(
      "Move destination does not match the connector start",
    );
  }
}

function validatePoint(point, path) {
  expectObject(point, path);
  requireExactKeys(point, ["x", "y"], path);
  expectCanonicalCoordinate(point.x, `${path}.x`);
  expectCanonicalCoordinate(point.y, `${path}.y`);
}

function pointsEqual(left, right) {
  return left.x === right.x && left.y === right.y;
}

function expectCanonicalCoordinate(value, path) {
  expectString(value, path);
  if (
    !/^-?(?:0|[1-9][0-9]*)(?:\.[0-9]*[1-9])?$/.test(value) ||
    value === "-0"
  ) {
    throw new EngineWireError(`${path} is not a canonical decimal string`);
  }
  const unsigned = value.startsWith("-") ? value.slice(1) : value;
  const [whole, fraction = ""] = unsigned.split(".");
  if (whole.length + fraction.length > 18 || fraction.length > 9) {
    throw new EngineWireError(`${path} exceeds the bounded decimal domain`);
  }
}

function expectNodeId(value, path) {
  expectString(value, path);
  if (!/^[A-Za-z_][A-Za-z0-9_-]*$/.test(value)) {
    throw new EngineWireError(`${path} is not a validated node identifier`);
  }
}

function expectBase16(value, path) {
  expectString(value, path);
  if (value.length % 2 !== 0 || !/^[0-9a-f]*$/.test(value)) {
    throw new EngineWireError(`${path} is not canonical lowercase base16`);
  }
}

function expectPortableOffset(value, path) {
  expectSafeUnsignedInteger(value, path);
  if (value > maximumPortableOffset) {
    throw new EngineWireError(`${path} exceeds the portable offset domain`);
  }
}

function expectSafeUnsignedInteger(value, path) {
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new EngineWireError(`${path} must be a safe unsigned integer`);
  }
}

function expectUnicodeString(value, path) {
  expectString(value, path);
  for (let index = 0; index < value.length; index += 1) {
    const codeUnit = value.charCodeAt(index);
    if (codeUnit >= 0xd800 && codeUnit <= 0xdbff) {
      const next = value.charCodeAt(index + 1);
      if (!(next >= 0xdc00 && next <= 0xdfff)) {
        throw new EngineWireError(`${path} contains an unpaired surrogate`);
      }
      index += 1;
    } else if (codeUnit >= 0xdc00 && codeUnit <= 0xdfff) {
      throw new EngineWireError(`${path} contains an unpaired surrogate`);
    }
  }
}

function expectString(value, path) {
  if (typeof value !== "string") {
    throw new EngineWireError(`${path} must be a string`);
  }
}

function expectBoolean(value, path) {
  if (typeof value !== "boolean") {
    throw new EngineWireError(`${path} must be a boolean`);
  }
}

function expectLiteral(value, expected, path) {
  if (value !== expected) {
    throw new EngineWireError(`${path} must equal ${JSON.stringify(expected)}`);
  }
}

function expectOneOf(value, choices, path) {
  const allowed = choices instanceof Set ? choices : new Set(choices);
  if (!allowed.has(value)) {
    throw new EngineWireError(`${path} has an unknown closed value`);
  }
}

function expectObject(value, path) {
  if (
    typeof value !== "object" ||
    value === null ||
    Array.isArray(value) ||
    Object.getPrototypeOf(value) !== Object.prototype
  ) {
    throw new EngineWireError(`${path} must be a JSON object`);
  }
}

function requireExactKeys(value, expectedKeys, path) {
  const actualKeys = Object.keys(value);
  if (
    actualKeys.length !== expectedKeys.length ||
    expectedKeys.some((key) => !Object.hasOwn(value, key))
  ) {
    throw new EngineWireError(`${path} contains missing or unknown fields`);
  }
}

function deepFreeze(value) {
  if (typeof value !== "object" || value === null || Object.isFrozen(value)) {
    return value;
  }
  for (const child of Object.values(value)) {
    deepFreeze(child);
  }
  return Object.freeze(value);
}
