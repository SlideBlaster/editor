/**
 * `slideblaster.session/1` envelope: requests, effects, view, closed response decoding.
 * Spec: `docs/specs/session-v1-protocol.md` (lane I). The host forwards facts and
 * interprets effects; it never derives revisions, ids or edits.
 */
import { validatePlan, type Plan } from "./plan.ts";
import { base16FromBytes, bytesFromBase16 } from "./product-v2.ts";

export const sessionProtocol = "slideblaster.session/1";

export { base16FromBytes, bytesFromBase16 };

export interface ByteRange {
  readonly start: number;
  readonly end: number;
}

export interface Enable {
  readonly enabled: boolean;
  readonly reason?: string;
}

export interface Fence {
  readonly session: number;
  readonly revision: number;
  readonly ticket: number;
  readonly surface: { readonly frame: string; readonly kind: "audience" | "notes" };
}

/** The included deck a slide comes from; `path` is its deck file relative to the including deck's folder. */
export interface SlideOrigin {
  readonly deck: string;
  readonly path: string;
  readonly readOnly: boolean;
  readonly code: string;
}

export interface NavigatorItem {
  readonly frame: string;
  readonly title: string;
  /** Id of the section the slide belongs to, when the deck has sections. */
  readonly section?: string | null;
  /** Id of the innermost sub-presentation section the slide belongs to, when it is included from another deck. */
  readonly subsection?: string | null;
  /** Set on a slide spliced in from an included deck: it is read-only here (`include.read_only`). */
  readonly origin?: SlideOrigin | null;
  readonly span: ByteRange;
  readonly steps: number;
  readonly audience: Plan | null;
  readonly notes: Plan | null;
}

export interface ViewDiagnostic {
  readonly severity: "error" | "warning" | "info";
  readonly code: string;
  readonly message: string;
  readonly span: ByteRange | null;
  readonly frame: string | null;
}

export interface PresenterView {
  readonly frame: string;
  readonly step: number;
  readonly steps: number;
  readonly audience: Plan;
  readonly notes: Plan | null;
  readonly next: Plan | null;
  /** Position in the audience-capped beat list; present when the core projects the zipper. */
  readonly cursor?: number;
  readonly total?: number;
  readonly slide?: { readonly number: number; readonly count: number };
  /** The active route: its id (null until a choice is made), the default route and the frames in order. */
  readonly route?: { readonly id: string | null; readonly default: string | null; readonly frames: readonly string[] };
  /** Route choices on the current slide, in reading order; digit keys 1..n select them. */
  readonly choices?: readonly { readonly route: string; readonly label: string }[];
}

export interface SectionView {
  readonly id: string;
  readonly title: string;
  readonly frames: readonly string[];
  readonly first: string | null;
  readonly last: string | null;
}

/** A section of an included deck, nested under the parent section (or top level when `parent` is null). */
export interface SubsectionView extends SectionView {
  readonly parent: string | null;
  readonly deck: string;
}

export interface RouteView {
  readonly id: string;
  readonly default: boolean;
  readonly sections: readonly string[];
  readonly frames: readonly string[];
}

export interface View {
  readonly revision: number;
  readonly session: number;
  readonly saved: number;
  readonly ready: boolean;
  /** The project's picture files (`.tikz`), which a slide can bring in with `\\cat`. */
  readonly pictureFiles?: readonly string[];
  /** Library files (`shapes/<family>.tikz`) the deck names styles from and the project lacks. */
  readonly needs?: readonly string[];
  readonly frontmatter: {
    readonly title: string;
    readonly theme: string;
    readonly aspect: string;
    readonly size: { readonly width: number; readonly height: number };
  };
  readonly navigator: {
    readonly activeIndex: number;
    readonly activeFrame: string | null;
    readonly slideCount: number;
    readonly items: readonly NavigatorItem[];
  };
  readonly active: { readonly fence: Fence; readonly plan: Plan; readonly step: number } | null;
  readonly diagnostics: readonly ViewDiagnostic[];
  readonly commands: Readonly<Record<string, Enable>>;
  readonly presenter: PresenterView | null;
  readonly sections?: readonly SectionView[];
  readonly subsections?: readonly SubsectionView[];
  readonly routes?: readonly RouteView[];
  readonly source?: { readonly sourceBase16: string };
}

export type Effect =
  | { readonly kind: "measure"; readonly ticket: number; readonly items: readonly { readonly key: string; readonly content: unknown; readonly width: number }[] }
  | { readonly kind: "block.render"; readonly ticket: number; readonly fingerprint: string; readonly request: Record<string, unknown> }
  | { readonly kind: "storage"; readonly op: "write"; readonly path: string; readonly bytesBase16: string; readonly revision: number }
  | { readonly kind: "file.write"; readonly path: string; readonly expectedBase16: string; readonly bytesBase16: string }
  | { readonly kind: "present"; readonly op: "open" | "close" | "goto"; readonly frame?: string; readonly step?: number; readonly window: "presenter" | "audience" }
  | { readonly kind: "print"; readonly frames: readonly string[] }
  | { readonly kind: "focus_node"; readonly [key: string]: unknown }
  | { readonly kind: "slide_selected"; readonly [key: string]: unknown }
  | { readonly kind: "slide_created"; readonly [key: string]: unknown }
  | { readonly kind: "node_created"; readonly frame: string; readonly node: string };

/** One canvas edit of a slide's picture block; points are plan pixels. */
export type PictureOp =
  | { readonly kind: "add_node"; readonly options: string; readonly x: number; readonly y: number; readonly text: string }
  | { readonly kind: "move_node"; readonly node: string; readonly x: number; readonly y: number }
  | { readonly kind: "attach"; readonly node: string; readonly side: string; readonly to: string; readonly distance: number | null }
  | { readonly kind: "style"; readonly item: string; readonly set: readonly { readonly key: string; readonly value: string | null }[]; readonly remove: readonly string[] }
  | { readonly kind: "resize"; readonly node: string; readonly width: number; readonly height: number }
  | { readonly kind: "set_text"; readonly node: string; readonly text: string }
  | { readonly kind: "connect"; readonly from: string; readonly to: string }
  | { readonly kind: "delete"; readonly item: string }
  | { readonly kind: "add_include"; readonly path: string; readonly x: number; readonly y: number }
  | { readonly kind: "move_include"; readonly item: string; readonly x: number; readonly y: number }
  | { readonly kind: "delete_many"; readonly items: readonly string[] }
  | { readonly kind: "reorder"; readonly node: string; readonly to: "front" | "back" | "forward" | "backward" }
  /** Picture statements (as copied) added to the slide, shifted right and down by plan pixels. */
  | { readonly kind: "paste"; readonly text: string; readonly x: number; readonly y: number }
  /** Several edits as one step (and one undo); a batch does not hold another batch. */
  | { readonly kind: "batch"; readonly ops: readonly PictureOp[] }
  /** How a line goes between its points; `bend` in degrees, or null for what it had. */
  | { readonly kind: "route"; readonly line: string; readonly to: "straight" | "hv" | "vh" | "bend left" | "bend right"; readonly bend: number | null }
  /** The text of a line's label (`index` from 1; 0 adds one); an empty text removes it. */
  | { readonly kind: "label"; readonly line: string; readonly index: number; readonly text: string }
  | { readonly kind: "label_style"; readonly line: string; readonly index: number; readonly set: readonly { readonly key: string; readonly value: string | null }[]; readonly remove: readonly string[] }
  /** Put a point into a line's step (from 1), move a written point (from 0), or take one out. */
  | { readonly kind: "add_point"; readonly line: string; readonly step: number; readonly x: number; readonly y: number }
  | { readonly kind: "move_point"; readonly line: string; readonly point: number; readonly x: number; readonly y: number }
  | { readonly kind: "remove_point"; readonly line: string; readonly point: number };

export interface SessionSuccess {
  readonly protocol: typeof sessionProtocol;
  readonly ok: true;
  readonly kind: string;
  readonly effects: readonly Effect[];
  readonly view: View;
}

export interface SessionFailure {
  readonly protocol: typeof sessionProtocol;
  readonly ok: false;
  readonly kind: "error";
  readonly error: { readonly code: string; readonly message: string };
}

export type SessionResponse = SessionSuccess | SessionFailure;

export type Request = { readonly protocol: typeof sessionProtocol; readonly command: string; readonly [key: string]: unknown };

export class SessionWireError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "SessionWireError";
  }
}

export interface RunPosition { readonly path: readonly number[]; readonly offset: number }

export interface StyleIntent {
  readonly nodeId: string;
  readonly themeDialect: "latex" | "markdown" | "html";
  readonly target: { readonly kind: "between"; readonly start: RunPosition; readonly end: RunPosition };
  readonly effect: { readonly kind: "toggle" | "set"; readonly style: Record<string, unknown> };
}

const request = (command: string, fields: Record<string, unknown> = {}): Request =>
  ({ protocol: sessionProtocol, command, ...fields });

export const requests = {
  openProject: (entry: string, files?: readonly { path: string; bytes: Uint8Array }[]): Request =>
    request("open_project", files === undefined
      ? { entry }
      : { entry, files: files.map((f) => ({ path: f.path, bytesBase16: base16FromBytes(f.bytes) })) }),
  openSource: (bytes: Uint8Array): Request => request("open_source", { sourceBase16: base16FromBytes(bytes) }),
  applySourceReplace: (revision: number, range: ByteRange, expected: Uint8Array, replacement: Uint8Array): Request =>
    request("apply_source_replace", {
      revision, start: range.start, end: range.end,
      expectedBase16: base16FromBytes(expected), replacementBase16: base16FromBytes(replacement),
    }),
  replaceSource: (revision: number, bytes: Uint8Array): Request =>
    request("replace_source", { revision, sourceBase16: base16FromBytes(bytes) }),
  command: (name: string, revision?: number): Request =>
    request("command", revision === undefined ? { name } : { name, revision }),
  selectSlide: (frame: string): Request => request("select_slide", { frame }),
  pictureEdit: (revision: number, frame: string, op: PictureOp): Request => request("picture_edit", { revision, frame, op }),
  imageRefs: (on: boolean): Request => request("image_refs", { on }),
  resources: (refs: readonly string[]): Request => request("resources", { refs }),
  figureEdit: (revision: number, figure: string, op: FigureOp): Request => request("figure_edit", { revision, figure, op }),
  activateNode: (surface: Fence["surface"], nodeId: string): Request => request("activate_node", { surface, nodeId }),
  pointerEvent: (event: Record<string, unknown>): Request => request("pointer_event", { event }),
  paintCompletion: (fence: Fence, outcome: "painted" | { failed: string }): Request =>
    request("paint_completion", { fence, outcome }),
  measurementResult: (ticket: number, results: readonly { key: string; width: number; height: number }[]): Request =>
    request("measurement_result", { ticket, results }),
  presentOpen: (startFrame?: string): Request => request("present_open", startFrame === undefined ? {} : { startFrame }),
  presentStep: (direction: "next" | "previous"): Request => request("present_step", { direction }),
  presentGoto: (frame: string, step?: number): Request => request("present_goto", step === undefined ? { frame } : { frame, step }),
  presentRoute: (route: string): Request => request("present_route", { route }),
  presentClose: (): Request => request("present_close"),
  /** TikZ node text styling, in the engine/1 `style_tikz_node` intent shape (123cf04). */
  styleNode: (revision: number, intent: StyleIntent): Request =>
    request("style_node", { revision, nodeId: intent.nodeId, themeDialect: intent.themeDialect, target: intent.target, effect: intent.effect }),
  workspaceSnapshot: (): Request => request("workspace_snapshot"),
  /** Browser-only mode (no native core): the host relays a provider outcome itself. */
  providerResult: (ticket: number, fingerprint: string, outcome: Record<string, unknown>): Request =>
    request("provider_result", { ticket, fingerprint, ...outcome }),
  storageResult: (path: string, revision: number, ok: boolean): Request => request("storage_result", { path, revision, ok }),
  projectFile: (path: string, bytes: Uint8Array | null): Request =>
    request("project_file", { path, bytesBase16: bytes === null ? null : base16FromBytes(bytes) }),
} as const;

const effectKinds = new Set(["measure", "block.render", "storage", "file.write", "present", "print", "focus_node", "slide_selected", "slide_created", "node_created"]);

/** Parse and validate a complete response before any of it reaches the DOM. */
export function decodeSessionResponse(raw: string | unknown): SessionResponse {
  let value: unknown = raw;
  if (typeof raw === "string") {
    try { value = JSON.parse(raw); } catch { throw new SessionWireError("response is not JSON"); }
  }
  const body = record(value, "response");
  if (body.protocol !== sessionProtocol) throw new SessionWireError("unsupported protocol in response");
  if (body.ok === false) {
    const error = record(body.error, "response.error");
    if (typeof error.code !== "string" || typeof error.message !== "string") throw new SessionWireError("malformed error");
    return body as unknown as SessionFailure;
  }
  if (body.ok !== true || typeof body.kind !== "string") throw new SessionWireError("malformed success envelope");
  if (!Array.isArray(body.effects)) throw new SessionWireError("response.effects must be an array");
  for (const effect of body.effects) {
    const kind = record(effect, "effect").kind;
    if (typeof kind !== "string" || !effectKinds.has(kind)) throw new SessionWireError(`unknown effect kind ${String(kind)}`);
  }
  validateView(body.view);
  return body as unknown as SessionSuccess;
}

function validateView(value: unknown): void {
  const view = record(value, "view");
  for (const key of ["revision", "session", "saved"]) {
    if (!Number.isSafeInteger(view[key])) throw new SessionWireError(`view.${key} must be an integer`);
  }
  if (typeof view.ready !== "boolean") throw new SessionWireError("view.ready must be boolean");
  const nav = record(view.navigator, "view.navigator");
  if (!Array.isArray(nav.items)) throw new SessionWireError("view.navigator.items must be an array");
  nav.items.forEach((item, i) => {
    const entry = record(item, `view.navigator.items[${i}]`);
    if (typeof entry.frame !== "string") throw new SessionWireError("navigator item frame must be a string");
    for (const surface of ["audience", "notes"]) {
      if (entry[surface] !== null) validatePlan(entry[surface], `view.navigator.items[${i}].${surface}`);
    }
  });
  if (view.active !== null) validatePlan(record(view.active, "view.active").plan, "view.active.plan");
  if (!Array.isArray(view.diagnostics)) throw new SessionWireError("view.diagnostics must be an array");
  record(view.commands, "view.commands");
  if (view.presenter !== null) {
    const presenter = record(view.presenter, "view.presenter");
    validatePlan(presenter.audience, "view.presenter.audience");
    if (presenter.notes !== null) validatePlan(presenter.notes, "view.presenter.notes");
    if (presenter.next !== null) validatePlan(presenter.next, "view.presenter.next");
  }
}

function record(value: unknown, path: string): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) throw new SessionWireError(`${path} must be an object`);
  return value as Record<string, unknown>;
}

/** A change to a TikZ figure the core draws itself; `at` is where the statement or node starts in the figure's text. */
export type FigureOp =
  | { readonly kind: "move"; readonly at: number; /** Centimetres, right and up. */ readonly dx: number; readonly dy: number }
  | { readonly kind: "text"; readonly at: number; readonly text: string }
  | { readonly kind: "option"; readonly at: number; readonly key: string; /** Empty writes the bare key; null takes the option away. */ readonly value: string | null }
  | { readonly kind: "delete"; readonly at: number }
  | { readonly kind: "add_node"; /** Where it stands in the picture: centimetres, y up. */ readonly x: number; readonly y: number; readonly options: string; readonly text: string }
  | { readonly kind: "add_line"; /** The nodes it joins. */ readonly from: number; readonly to: number; readonly options: string }
  | { readonly kind: "resize"; readonly at: number; /** At least so big, in centimetres. */ readonly width: number; readonly height: number }
  | { readonly kind: "route"; readonly at: number; readonly to: "straight" | "hv" | "vh" | "bend left" | "bend right" }
  | { readonly kind: "batch"; readonly ops: readonly FigureOp[] };
