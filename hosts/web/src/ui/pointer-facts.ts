/**
 * Raw pointer/keyboard facts for the interactive surface. The host maps the DOM event into
 * plan pixels and forwards it; press/drag/preview/commit/cancel policy is the core's.
 * Ordering is delegated to the existing one-unresolved-move-per-pointer transport.
 */
import { createPointerEventTransport } from "./pointer-event-transport.ts";
import type { Plan } from "../protocol/plan.ts";
import type { Fence } from "../protocol/session.ts";

export interface PointerSink {
  /** Send a closed pointer fact; resolves when the core has answered. */
  pointer(fact: Record<string, unknown>): Promise<unknown>;
  activate(surface: Fence["surface"], nodeId: string): Promise<unknown>;
}

const round = (n: number): number => Math.round(n * 1000) / 1000;

/** Plan-pixel point for a client point, or null when outside the painted slide. */
export function clientToPlan(clientX: number, clientY: number, rect: { left: number; top: number; width: number; height: number }, plan: Pick<Plan, "size">, clamp = false): { x: number; y: number } | null {
  if (!(rect.width > 0) || !(rect.height > 0)) return null;
  let u = (clientX - rect.left) / rect.width;
  let v = (clientY - rect.top) / rect.height;
  if (clamp) { u = Math.min(1, Math.max(0, u)); v = Math.min(1, Math.max(0, v)); }
  if (!(u >= 0 && u <= 1 && v >= 0 && v <= 1)) return null;
  return { x: round(u * plan.size.width), y: round(v * plan.size.height) };
}

export function attachPointerFacts(slide: HTMLElement, plan: Plan, sink: PointerSink): () => void {
  const surface: Fence["surface"] = { frame: plan.frame, kind: plan.surface };
  const transport = createPointerEventTransport((fact: Record<string, unknown>) => sink.pointer(fact));
  const tracked = new Set<number>();

  const fact = (type: string, event: PointerEvent, target?: Record<string, unknown>, clamp = false): Record<string, unknown> | null => {
    const point = clientToPlan(event.clientX, event.clientY, slide.getBoundingClientRect(), plan, clamp);
    if (point === null) return null;
    const result: Record<string, unknown> = {
      type, pointerId: event.pointerId, pointerType: event.pointerType, button: event.button, primary: event.isPrimary,
      cssPoint: { x: round(event.clientX), y: round(event.clientY) }, slidePoint: point,
      modifiers: { alt: event.altKey, shift: event.shiftKey, control: event.ctrlKey, meta: event.metaKey },
    };
    if (target !== undefined) result.target = target;
    return result;
  };

  const down = (event: PointerEvent) => {
    const hit = (event.target as Element).closest?.(".sb-hit") as HTMLElement | null;
    const target = hit === null ? { kind: "canvas" } : { kind: "node", surface, nodeId: hit.dataset.nodeId };
    const f = fact("down", event, target);
    if (f === null) return;
    tracked.add(event.pointerId);
    void transport.begin(f, () => {
      try { (hit ?? slide).setPointerCapture(event.pointerId); } catch { /* synthetic input */ }
    });
    event.preventDefault();
  };
  const move = (event: PointerEvent) => {
    if (!tracked.has(event.pointerId)) return;
    const f = fact("move", event);
    if (f !== null) transport.move(f);
  };
  const up = (event: PointerEvent) => {
    if (!tracked.has(event.pointerId)) return;
    tracked.delete(event.pointerId);
    const f = fact("up", event, undefined, true);
    if (f === null) transport.cancel(event.pointerId, { type: "cancel", pointerId: event.pointerId });
    else transport.finish(event.pointerId, { ...f, type: "move" }, f);
  };
  const cancel = (event: PointerEvent) => {
    if (!tracked.delete(event.pointerId)) return;
    transport.cancel(event.pointerId, { type: "cancel", pointerId: event.pointerId });
  };
  const key = (event: KeyboardEvent) => {
    const hit = (event.target as Element).closest?.(".sb-hit") as HTMLElement | null;
    if (hit === null || (event.key !== "Enter" && event.key !== " ")) return;
    event.preventDefault();
    void sink.activate(surface, hit.dataset.nodeId ?? "");
  };
  slide.addEventListener("pointerdown", down, true);
  slide.addEventListener("pointermove", move, true);
  slide.addEventListener("pointerup", up, true);
  slide.addEventListener("pointercancel", cancel, true);
  slide.addEventListener("keydown", key, true);
  slide.addEventListener("dragstart", (e) => e.preventDefault());
  return () => {
    for (const id of tracked) transport.cancel(id, { type: "lost_capture", pointerId: id });
    tracked.clear();
    slide.removeEventListener("pointerdown", down, true);
    slide.removeEventListener("pointermove", move, true);
    slide.removeEventListener("pointerup", up, true);
    slide.removeEventListener("pointercancel", cancel, true);
    slide.removeEventListener("keydown", key, true);
  };
}
