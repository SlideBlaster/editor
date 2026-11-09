/** Return the bounded, source-redacted record permitted in DOM test telemetry. */
export function redactProtocolExchange(request, response) {
  const requestTrace: Record<string, any> = {
    command: typeof request?.command === "string" ? request.command : "invalid",
    keys: Object.keys(request ?? {}).sort(),
  };
  if (request?.event !== undefined) {
    requestTrace.event = redactPointerEvent(request.event);
  }
  if (typeof request?.viewCommand === "string") {
    requestTrace.viewCommand = request.viewCommand;
  }
  if (request?.paint !== undefined) {
    requestTrace.paint = {
      session: request.paint?.session,
      revision: request.paint?.revision,
      ticket: request.paint?.ticket,
    };
  }

  const responseTrace: Record<string, any> = response?.ok === true
    ? { kind: response.kind, actions: response.actions?.map((action) => action.kind) ?? [] }
    : { kind: "error", errorCode: response?.error?.code ?? "invalid_response" };
  const workspace = response?.ok === true ? response.workspace : null;
  if (workspace !== null && typeof workspace === "object") {
    responseTrace.sourceRevision = workspace.source?.revision;
    responseTrace.pointerPhase = workspace.pointer?.phase;
    responseTrace.selection = workspace.selection;
    if (workspace.preview !== null && workspace.preview !== undefined) {
      responseTrace.preview = {
        nodeId: workspace.preview.nodeId,
        centre: redactPoint(workspace.preview.centre),
        freeDrag: workspace.preview.freeDrag,
        guides: Array.isArray(workspace.preview.guides)
          ? workspace.preview.guides.map((guide) => guide.kind)
          : [],
        outcome: workspace.preview.outcome,
      };
    }
  }
  return Object.freeze({ request: requestTrace, response: responseTrace });
}

function redactPointerEvent(event) {
  const result: Record<string, any> = {
    type: event?.type,
    pointerId: event?.pointerId,
  };
  if (event?.target?.kind !== undefined) result.targetKind = event.target.kind;
  if (event?.target?.nodeId !== undefined) result.nodeId = event.target.nodeId;
  if (event?.modifiers !== undefined) {
    result.modifiers = {
      alt: event.modifiers.alt,
      shift: event.modifiers.shift,
      control: event.modifiers.control,
      meta: event.modifiers.meta,
    };
  }
  return result;
}

function redactPoint(value) {
  return { x: exactValue(value?.x), y: exactValue(value?.y) };
}

function exactValue(value) {
  return value !== null && typeof value === "object" ? value.exact : value;
}
