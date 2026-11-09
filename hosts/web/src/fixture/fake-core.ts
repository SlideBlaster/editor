/**
 * FIXTURE STAND-IN for `sb serve`'s `/session` endpoint: a `SessionTransport` that
 * answers session/1 commands from the sample deck so the UI, presenter and smoke tests
 * run without the native core. It honours the revision/expected-bytes fences the real
 * core enforces; it does no deck parsing beyond reading `## Title {#id}` headings to
 * make edits visible. It is never used when a real transport is available.
 */
import { decodeSessionResponse, sessionProtocol, bytesFromBase16, type Effect, type Request, type SessionResponse, type SessionSuccess, type View } from "../protocol/session.ts";
import type { ConnectionState, SessionTransport } from "../transport/transport.ts";
import { buildSampleView, sampleDefs, samplePlanFor, type SampleOptions } from "./sample-view.ts";

export interface FakeCoreOptions {
  readonly source: Uint8Array;
  readonly logos?: Readonly<Record<string, string>>;
  /** Milliseconds until the figure "compiles"; `null` = already compiled. */
  readonly figureDelayMs?: number | null;
  readonly figure?: "compiled" | "stale" | "absent";
}

const decoder = new TextDecoder();
const encoder = new TextEncoder();

export function createFakeCore(options: FakeCoreOptions): SessionTransport & { readonly debug: () => { revision: number; source: string; cursor: number } } {
  let source = options.source;
  let revision = 0;
  let saved = 0;
  let activeFrame = "title";
  let activeStep: number | undefined;
  let cursor = 0;
  let presenting = false;
  let figure: SampleOptions["figure"] = options.figureDelayMs === null || options.figureDelayMs === undefined ? (options.figure ?? "compiled") : "pending";
  const history: Uint8Array[] = [];
  const redoStack: Uint8Array[] = [];
  const pushListeners = new Set<(push: SessionSuccess) => void>();
  const stateListeners = new Set<(state: ConnectionState) => void>();
  const beats = sampleDefs.flatMap((def, index) => Array.from({ length: def.steps }, (_, step) => ({ index, step, frame: def.frame })));

  function titles(): Record<string, string> {
    const result: Record<string, string> = {};
    const text = decoder.decode(source);
    const front = /^title:\s*"?(.*?)"?\s*$/m.exec(text);
    if (front?.[1] !== undefined) result.title = front[1];
    for (const line of text.split("\n")) {
      const match = /^## (.*?)(?: \{#([a-z0-9-]+)\})?\s*$/.exec(line);
      if (match?.[2] !== undefined && match[1] !== undefined) result[match[2]] = match[1];
    }
    return result;
  }

  function view(): View {
    const base = buildSampleView({
      revision, source, saved, titles: titles(), figure, logos: options.logos, activeFrame, activeStep,
    });
    const beat = beats[cursor]!;
    const def = sampleDefs[beat.index]!;
    const opts: SampleOptions = { revision, source, saved, titles: titles(), figure, logos: options.logos };
    const nextBeat = beats[cursor + 1];
    const presenter = !presenting ? null : {
      frame: beat.frame, step: beat.step + 1, steps: def.steps,
      cursor, total: beats.length, slide: { number: beat.index + 1, count: sampleDefs.length },
      audience: samplePlanFor(def, beat.index, sampleDefs.length, beat.step, opts, "audience"),
      notes: def.notes === undefined ? null : samplePlanFor(def, beat.index, sampleDefs.length, beat.step, opts, "notes"),
      next: nextBeat === undefined ? null : samplePlanFor(sampleDefs[nextBeat.index]!, nextBeat.index, sampleDefs.length, nextBeat.step, opts, "audience"),
    };
    return { ...base, presenter };
  }

  function ok(kind: string, effects: Effect[] = [], withSource = false): SessionResponse {
    const v = view();
    return decodeSessionResponse({
      protocol: sessionProtocol, ok: true, kind, effects,
      view: withSource ? { ...v, source: { sourceBase16: [...source].map((b) => b.toString(16).padStart(2, "0")).join("") } } : v,
    });
  }
  const error = (code: string, message: string): SessionResponse =>
    ({ protocol: sessionProtocol, ok: false, kind: "error", error: { code, message } });

  function applyBytes(next: Uint8Array): void {
    history.push(source);
    redoStack.length = 0;
    source = next;
    revision += 1;
  }

  function handle(req: Request): SessionResponse {
    switch (req.command) {
      case "open_project": case "workspace_snapshot": return ok(req.command === "open_project" ? "project_opened" : "workspace_snapshot", [], req.command === "open_project");
      case "open_source": source = bytesFromBase16(String(req.sourceBase16)); revision = 0; saved = 0; return ok("source_opened", [], true);
      case "apply_source_replace": {
        if (req.revision !== revision) return error("stale_revision", "The source changed since this edit was made");
        const start = Number(req.start); const end = Number(req.end);
        const expected = bytesFromBase16(String(req.expectedBase16));
        const current = source.slice(start, end);
        if (current.length !== expected.length || current.some((b, i) => b !== expected[i])) return error("expected_mismatch", "The replaced bytes are not the expected bytes");
        const insert = bytesFromBase16(String(req.replacementBase16));
        applyBytes(Uint8Array.from([...source.slice(0, start), ...insert, ...source.slice(end)]));
        return ok("source_replaced");
      }
      case "replace_source":
        if (req.revision !== revision) return error("stale_revision", "The source changed since this edit was made");
        applyBytes(bytesFromBase16(String(req.sourceBase16)));
        return ok("source_replaced", [], true);
      case "select_slide": {
        const frame = String(req.frame);
        if (!sampleDefs.some((d) => d.frame === frame)) return error("invalid_field", "unknown frame");
        activeFrame = frame; activeStep = undefined;
        return ok("slide_selected", [{ kind: "slide_selected", frame }]);
      }
      case "command":
        switch (req.name) {
          case "next_slide": case "previous_slide": {
            const index = sampleDefs.findIndex((d) => d.frame === activeFrame) + (req.name === "next_slide" ? 1 : -1);
            const def = sampleDefs[Math.max(0, Math.min(sampleDefs.length - 1, index))]!;
            activeFrame = def.frame; activeStep = undefined;
            return ok("view_updated");
          }
          case "undo": { const prior = history.pop(); if (prior === undefined) return error("history_unavailable", "Nothing to undo"); redoStack.push(source); source = prior; revision += 1; return ok("undo", [], true); }
          case "redo": { const next = redoStack.pop(); if (next === undefined) return error("history_unavailable", "Nothing to redo"); history.push(source); source = next; revision += 1; return ok("redo", [], true); }
          case "save": saved = revision; return ok("saved");
          default: return error("invalid_field", `unsupported command ${String(req.name)}`);
        }
      case "present_open": {
        presenting = true;
        const start = typeof req.startFrame === "string" ? beats.findIndex((b) => b.frame === req.startFrame) : 0;
        cursor = Math.max(0, start);
        return ok("present_opened", [{ kind: "present", op: "open", window: "presenter", frame: beats[cursor]!.frame, step: beats[cursor]!.step + 1 }]);
      }
      case "present_step":
        if (!presenting) return error("invalid_field", "not presenting");
        cursor = Math.max(0, Math.min(beats.length - 1, cursor + (req.direction === "next" ? 1 : -1)));
        return ok("present_stepped");
      case "present_goto": {
        if (!presenting) return error("invalid_field", "not presenting");
        const at = beats.findIndex((b) => b.frame === req.frame && (typeof req.step !== "number" || b.step + 1 === req.step));
        if (at < 0) return error("invalid_field", "unknown beat");
        cursor = at;
        return ok("present_stepped");
      }
      case "present_close": presenting = false; return ok("present_closed", [{ kind: "present", op: "close", window: "presenter" }]);
      case "paint_completion": case "acknowledge_paint": case "measurement_result": case "pointer_event": case "activate_node":
        return ok("accepted");
      default: return error("unknown_command", `unknown command ${req.command}`);
    }
  }

  if (options.figureDelayMs !== null && options.figureDelayMs !== undefined) {
    setTimeout(() => {
      figure = options.figure ?? "compiled";
      const push = ok("view_updated");
      if (push.ok) for (const listener of [...pushListeners]) listener(push);
    }, options.figureDelayMs);
  }

  return {
    request: async (req) => handle(req),
    onPush: (listener) => { pushListeners.add(listener); return () => pushListeners.delete(listener); },
    onState: (listener) => { stateListeners.add(listener); return () => stateListeners.delete(listener); },
    state: () => "open",
    close: () => {},
    debug: () => ({ revision, source: decoder.decode(source), cursor }),
  };
}

export { encoder as fakeCoreEncoder };
