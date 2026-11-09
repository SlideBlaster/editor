/**
 * Bound raw pointer move delivery to one unresolved dispatch per pointer.
 * This queue owns transport ordering only; it does not interpret gestures.
 */
export function createPointerEventTransport(dispatch) {
  if (typeof dispatch !== "function") throw new TypeError("Pointer transport requires dispatch");
  const pointers = new Map<number, any>();

  function send(fact) {
    try {
      return Promise.resolve(dispatch(fact)).catch(() => undefined);
    } catch {
      return Promise.resolve(undefined);
    }
  }

  function begin(fact, onAdmitted = () => {}) {
    const previous = pointers.get(fact.pointerId);
    if (previous?.phase === "active") return previous.down;
    const state: any = {
      phase: "active",
      predecessorPending: previous?.phase === "terminal",
      downSettled: false,
      inFlightMove: null,
      pendingMove: null,
      terminalFact: null,
      terminalPromise: null,
      terminalDispatch: null,
      resolveTerminal: null,
      down: null,
    };
    pointers.set(fact.pointerId, state);

    const dispatchDown = () => {
      state.predecessorPending = false;
      onAdmitted();
      const pending = send(fact);
      state.down = pending;
      pending.then(() => {
        state.downSettled = true;
        drain(state);
      });
      return pending;
    };
    state.down = state.predecessorPending
      ? previous.terminalPromise.then(dispatchDown)
      : dispatchDown();
    return state.down;
  }

  function move(fact) {
    const state = pointers.get(fact.pointerId);
    if (state?.phase !== "active") return Promise.resolve(undefined);
    if (!state.downSettled || state.inFlightMove !== null) {
      state.pendingMove = fact;
      return state.inFlightMove ?? state.down;
    }
    return dispatchMove(state, fact);
  }

  function dispatchMove(state, fact) {
    const pending = send(fact);
    state.inFlightMove = pending;
    pending.then(() => {
      if (state.inFlightMove !== pending) return;
      state.inFlightMove = null;
      drain(state);
    });
    return pending;
  }

  function finish(pointerId, finalMove, terminalFact) {
    const state = pointers.get(pointerId);
    if (state === undefined || state.phase !== "active") {
      return state?.terminalPromise ?? Promise.resolve(undefined);
    }
    state.phase = "terminal";
    state.pendingMove = finalMove;
    state.terminalFact = terminalFact;
    state.terminalPromise = new Promise((resolve) => { state.resolveTerminal = resolve; });
    drain(state);
    return state.terminalPromise;
  }

  function cancel(pointerId, terminalFact) {
    const state = pointers.get(pointerId);
    if (state === undefined || state.phase !== "active") {
      return state?.terminalPromise ?? Promise.resolve(undefined);
    }
    state.phase = "terminal";
    state.pendingMove = null;
    state.terminalFact = terminalFact;
    state.terminalPromise = new Promise((resolve) => { state.resolveTerminal = resolve; });
    drain(state);
    return state.terminalPromise;
  }

  function drain(state) {
    if (!state.downSettled || state.inFlightMove !== null) return;
    if (state.pendingMove !== null) {
      const fact = state.pendingMove;
      state.pendingMove = null;
      dispatchMove(state, fact);
      return;
    }
    if (state.phase !== "terminal" || state.terminalFact === null || state.terminalDispatch !== null) return;
    const fact = state.terminalFact;
    state.terminalFact = null;
    state.terminalDispatch = send(fact);
    state.terminalDispatch.then(() => state.resolveTerminal?.());
  }

  return Object.freeze({
    begin,
    move,
    finish,
    cancel,
    isActive(pointerId) { return pointers.get(pointerId)?.phase === "active"; },
    isTerminal(pointerId) { return pointers.get(pointerId)?.phase === "terminal"; },
    isSettling(pointerId) { return pointers.get(pointerId)?.predecessorPending === true; },
  });
}
