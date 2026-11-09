---
status: accepted
updated: 2026-07-23
---

# Vertical slice: application history, leases, and command policy

## Demonstration

The shared `slideblaster-app` package now executes four application laws without
a DOM:

1. direct source changes, undo, and redo share branching exact-byte history;
2. undo/redo restore old bytes under a fresh monotonic revision;
3. delayed document analysis and paint cannot replace a newer draft or regain
   canvas edit authority; and
4. web and native compositions receive the same enabled/disabled decision for
   project, deck, source, canvas, property, theme, presenter, and export
   commands.

The current browser has not adopted this reducer yet. This specification
separates implemented state semantics from composition status.

## Session authorities

`DocumentSession syntax key` retains:

```text
SessionId
SourceHistory
Maybe (DocumentSnapshot syntax key Presentation)
Map SurfaceAddress CanvasAuthority
Map SurfaceAddress PaintRequest
next RenderTicket
```

The current `SourceHistory` snapshot is authoritative, including syntax-only
and invalid source. The accepted document may be absent or lagging. Its
semantic presentation is exposed only when both revision and exact bytes match
the current draft.

A new draft or history transition clears every pending paint request and retains
each last-good painted surface only as inert authority. It immediately stops
accepting canvas-derived edits. Accepting current analysis likewise revokes old
authorities while the new semantic presentation is measured and painted.

## Exact source history

History stores exact `ByteString` entries, not semantic trees, syntax objects,
render plans, selections, or DOM.

| Operation | Result |
| --- | --- |
| Record identical bytes | `HistoryNoOp`; revision and redo branch are unchanged. |
| Record changed bytes | Advance once, push current bytes to undo, clear redo. |
| Undo | Restore prior bytes through `advanceSnapshot`, push current bytes to redo. |
| Redo | Restore later bytes through `advanceSnapshot`, push current bytes to undo. |
| Empty undo/redo | `HistoryNoOp`; command policy also exposes the boundary. |

Using fresh revisions means restored bytes reparse and reacquire provenance and
render authority. Stale identities are never revived from history.

## Painted canvas leases

An opaque issued `PaintRequest` and the resulting `PaintedCanvasLease` are both
fenced by:

```text
SessionId × Revision × RenderTicket × SurfaceAddress
```

Ready analysis enumerates every audience surface and each present notes surface
in the non-empty `Presentation`. It issues one monotonically ticketed request
per `SurfaceAddress`, replacing the pending-request map for that revision.
Tickets are unique even across surfaces; their order is deterministic
presentation order.

A `PaintCompleted` event must echo the exact `PaintRequest` still held for that
surface. The reducer consumes that request before `acknowledgePaint` compares
the plan's revision, ticket, and surface. Therefore neither a stale completion
nor a newly invented but internally self-consistent plan can acquire authority.
Successful completion updates only the addressed surface's authority; the
other audience/notes requests and leases are independent.

`authorityAllowsEdit` requires the exact request and all four fence values to
match. Any newer draft, syntax-only result, pending measurement/paint, removed
surface, or superseded request makes the old plan inert.

The source-edit transaction still has to perform provenance-guided projection,
exact replacement, reparse, elaboration, and semantic verification. A writable
lease is necessary, not sufficient, for a source commit.

## Commands

Commands are closed values grouped by product meaning:

- project and Git;
- source history;
- deck and notes structure;
- direct source;
- canvas creation/edit;
- node, connector, frame, overlay, and animation properties;
- theme edit/import/save;
- panels, zoom, pan, and overlay preview;
- presenter start/stop/navigation; and
- export analyze/confirm/generate/cancel/download.

`commandAvailability` reports a non-empty set of typed disabled reasons.
Important policies include:

- source Save remains available for syntax-only documents when storage exists;
- Git commit/push require Git capability and diagnostics from the exact current
  revision; pending/stale diagnostics and current hard diagnostics both block;
- addressed node, connector, and canvas writes require a ready semantic
  document and the writable lease for that exact `SurfaceAddress`;
- deck structure, frame rotation, animations, and theme application require
  current semantic readiness but do not borrow an arbitrary canvas lease;
- presenter start requires a non-empty deck plus window, channel, and clock
  capabilities;
- HTML/LaTeX/PDF generation requires semantic readiness;
- PDF additionally requires print capability;
- workspace archive requires storage and archive capability; and
- a lossy export cannot generate until warnings are confirmed.

The UI may render these reasons but may not replace the policy.

## App model and reducer

`AppModel` combines the document session with semantic selection/tool/view
state, target capabilities, optional presenter state, and export jobs.
JavaScript handles, file handles, Blob URLs, and DOM nodes are excluded.

The initial reducer events are:

- draft bytes changed;
- undo/redo;
- document analysis completed;
- paint completed;
- presenter start/stop/move.

The reducer emits typed effects:

- analyze one exact snapshot;
- measure/render one exact semantic snapshot and issued surface request; or
- publish synchronized presenter views.

Ready analysis emits one `MeasureAndRender PaintRequest SourceBufferSnapshot
Presentation` effect per semantic surface. Target adapters interpret effects
and return the unchanged request with the completed plan. They never mint
requests, mutate application state directly, or collapse audience and notes
surfaces into one authority.

## Executable laws

`packages/slideblaster-app/test/Main.hs` covers:

- no-op history and redo-branch invalidation;
- fresh revisions across undo/redo;
- syntax-only save and typed presenter/export refusal;
- exact per-surface lease acquisition/revocation;
- stale, mismatched, and unsolicited paint rejection;
- draft-to-analysis effect correlation;
- stale analysis rejection;
- ready analysis producing distinct audience/notes measurement-render work for
  the current revision; and
- Git commit/push refusal while diagnostics are absent or stale.

## Next composition increment

Wire the existing Wasm reactor and browser host to hold one long-lived
`AppModel`, expose versioned app events/effects, and drive one source edit plus
one exact audience/notes paint request and acknowledgement. That increment must
reuse this reducer rather than keeping browser-owned revision/history or
paint-correlation policy.
