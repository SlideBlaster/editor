/**
 * TikZ styling toolbar, re-added on the new host (it was lost in the Product/2 merge;
 * recovered from 123cf04 `hosts/web/src/main.js`). The buttons act on the text the user has
 * selected inside a painted node. A selection is two positions, each a run path and a
 * character offset, read straight from the DOM: every styled run carries its own
 * `data-run-path`. The host sends the toggle/set intent and adopts whatever verified source
 * the core returns: whether B bolds or unbolds depends on the constructs the selection
 * covers, and that is Haskell's to answer.
 */
import { requests, type Request, type RunPosition, type StyleIntent } from "../protocol/session.ts";

export interface SelectionLike {
  readonly rangeCount: number;
  getRangeAt(index: number): { startContainer: Node; startOffset: number; endContainer: Node; endOffset: number };
}

export interface CanvasSelection {
  readonly nodeId: string;
  readonly start: RunPosition;
  readonly end: RunPosition;
}

export function readCanvasSelection(selection: SelectionLike | null): CanvasSelection | null {
  if (selection === null || selection.rangeCount === 0) return null;
  const range = selection.getRangeAt(0);
  const start = runPositionOf(range.startContainer, range.startOffset);
  const end = runPositionOf(range.endContainer, range.endOffset);
  if (start === null || end === null || start.nodeId !== end.nodeId) return null;
  if (start.path.length === end.path.length && start.path.every((index, at) => index === end.path[at]) && start.offset === end.offset) return null;
  return { nodeId: start.nodeId, start: { path: start.path, offset: start.offset }, end: { path: end.path, offset: end.offset } };
}

function runPositionOf(container: Node, offset: number): (RunPosition & { nodeId: string }) | null {
  const element = (container.nodeType === 3 ? container.parentElement : container) as Element | null;
  const run = element?.closest?.("[data-run-path]") as HTMLElement | null | undefined;
  if (run === null || run === undefined) return null;
  const owner = run.closest("[data-node-id]") as HTMLElement | null;
  if (owner === null) return null;
  const path = (run.dataset.runPath ?? "").split(".").filter((p) => p.length > 0).map((p) => Number.parseInt(p, 10));
  if (path.some((index) => !Number.isSafeInteger(index) || index < 0)) return null;
  return { nodeId: owner.dataset.nodeId ?? "", path, offset };
}

/** A style value in the wire vocabulary; the property decides keyword vs flag. */
export function styleValueFrom(property: string, rawValue: string): Record<string, unknown> {
  if (property === "underline" || property === "strike" || property === "highlight") return { property, value: rawValue === "true" };
  if (property === "foreground" || property === "background") {
    // The expression crosses as text; what "blue!40!black" means is xcolor's, and lives in Haskell.
    return { property, colour: { kind: "expression", text: rawValue } };
  }
  return { property, value: rawValue };
}

export function themeDialectOf(value: string): StyleIntent["themeDialect"] {
  if (value === "latex" || value === "markdown" || value === "html") return value;
  throw new Error(`unknown notation choice: ${value}`);
}

export interface StyleToolbarDeps {
  readonly root: ParentNode;
  readonly selection: () => SelectionLike | null;
  readonly revision: () => number | null;
  readonly send: (request: Request) => Promise<{ ok: boolean; message?: string }>;
  readonly status: (message: string) => void;
}

export function installStyleToolbar(deps: StyleToolbarDeps): { setEnabled(enabled: boolean): void } {
  const buttons = [...deps.root.querySelectorAll<HTMLButtonElement>("[data-style-property]")];
  const colour = deps.root.querySelector<HTMLInputElement>("#style-foreground");
  const apply = deps.root.querySelector<HTMLButtonElement>("#style-apply-colour");
  const dialect = deps.root.querySelector<HTMLSelectElement>("#theme-dialect");

  async function run(style: Record<string, unknown>, effect: "toggle" | "set"): Promise<void> {
    const selection = readCanvasSelection(deps.selection());
    if (selection === null) return deps.status("Select text inside a node on the canvas first");
    const revision = deps.revision();
    if (revision === null) return deps.status("Open a deck first");
    const intent: StyleIntent = { ...selection, themeDialect: themeDialectOf(dialect?.value ?? "latex"), target: { kind: "between", start: selection.start, end: selection.end }, effect: { kind: effect, style } };
    const result = await deps.send(requests.styleNode(revision, intent));
    deps.status(result.ok ? "Verified Haskell style change adopted as exact source" : (result.message ?? "That style command was not applied"));
  }

  for (const button of buttons) {
    button.addEventListener("click", () => { void run(styleValueFrom(button.dataset.styleProperty ?? "", button.dataset.styleValue ?? ""), "toggle"); });
  }
  apply?.addEventListener("click", () => {
    const expression = colour?.value.trim() ?? "";
    if (expression.length === 0) return deps.status("Enter a colour expression first");
    void run(styleValueFrom("foreground", expression), "set");
  });
  return { setEnabled(enabled) { for (const b of [...buttons, ...(apply === null ? [] : [apply])]) b.disabled = !enabled; } };
}
