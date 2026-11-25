# SB2-20260727-001 steering log

## STR-001

- Received: `2026-07-27`
- Source: `initiating product-owner message`
- Affects: `entire session`
- Disposition: `applied`

The product owner requires the full governed Stage 0–9 lifecycle, specified
specialist independence, a shared Markdown bus as the only monitor-agent
coordination channel, exact-source laws, cheapest-first verification, exact diff
review, and approval-gated integration/closure. This session applies those
requirements directly. No product-facing semantic choice has yet been inferred.

## STR-002

- Received: `2026-07-27 15:20 CEST`
- Source: `product owner live steering steer-80547fd7aea648bc869c762ce6e4968d`
- Affects: `continuation and pacing`
- Disposition: `applied`

The product owner asked the orchestrator to continue with the remaining work.
The orchestrator continued immediately through both parallel Stage 1 analyses
and independent Stage 2 design. Continuation does not waive explicit governance
gates: design discovered a durable protocol-boundary choice, so dependent
product mutation is paused for the separate decision required by `AGENTS.md`.

## STR-003

- Received: `2026-07-27 15:40 CEST`
- Source: `product owner`
- Affects: `durable protocol boundary and delegated Haskell implementation`
- Disposition: `accepted and applied`

The product owner delegated the Haskell implementation choice after the
protocol question was restated in plain language. The orchestrator selects the
recommended safe option: add source-authoritative `slideblaster.product/2`, keep
`slideblaster.product/1` unchanged for compatibility, and do not delete `/1` in
this session. This resolves the Stage 2 durable-boundary gate. The delegation
covers reversible implementation details inside the accepted source laws; it
does not waive later artifact observation, exact-change approval, integration
authorization, or session-closure gates.

## STR-004

- Received: `2026-07-28 10:24 CEST`
- Source: `product owner`
- Affects: `second-revision scope, roadmap ordering, and swarm size`
- Disposition: `accepted and applied`

The product owner explicitly authorizes reshaping the active slice and changing
roadmap implementation order when there is a documented product-improvement
reason. The second revision may therefore pull the minimum coherent deck,
interaction, zoom, snapping, and Markdown-container foundations into P0 instead
of preserving the earlier bounded technical proof. Work must still remain one
governed active slice, preserve source laws, avoid unrelated feature breadth,
and stop at unresolved product-facing format choices. The owner also directed
the orchestrator not to wait for a fourth agent; second-revision research used
exactly three parallel read-only agents, with synthesis retained by the
orchestrator.

## STR-005

- Received: `2026-07-28 10:58 CEST`
- Source: `product owner`
- Affects: `Product/2 browser/Wasm responsibility boundary`
- Disposition: `accepted; corrective refactor required before further feature work`

The product owner confirmed that the accumulating JavaScript interaction
controller is not an acceptable architecture. Product/2 must use the real GHC
Wasm JSFFI boundary while keeping gesture phase, threshold, selection/drag
policy, snapping, commit/cancel, command availability, zoom state, and navigator
projection in Haskell. JavaScript is restricted to Wasm instantiation, raw DOM
event capture and frame-rate sample coalescing, pointer-capture/browser effects,
closed projection validation, and DOM/SVG painting. The interrupted I5 browser
edits are unverified work-in-progress and must be reviewed/reworked under this
boundary rather than treated as completed evidence.

## STR-006

- Received: `2026-07-28 13:05 CEST`
- Source: `product owner`
- Affects: `durable deck format design`
- Disposition: `pending product-owner design direction`

The product owner rejected the inherited `slide` versus `tikz` fence-label
choice as insufficiently smooth or concrete and requested a fresh design agent.
An independent read-only designer evaluated three format families from first
principles: a minimal legacy hybrid, a Markdown-native directive format, and a
structured YAML deck. The designer recommends a staged Markdown-native format:
ordinary Markdown for titles and flow content, with exact line-oriented
namespaced HTML comments only for stable slide, positioned-object, and notes
boundaries. No syntax is accepted or implemented yet; choosing this family
would supersede legacy format assumptions and therefore remains an explicit
product-owner gate.

## STR-007

- Received: `2026-07-28 13:20 CEST`
- Source: `product owner`
- Affects: `P0 deck container, source format, New Slide, navigator`
- Disposition: `accepted for a bounded SlideBlaster2 trial`

The product owner approved trying the revised frame-like syntax represented by
`temp/demo.slide`. The trial model is:

- `deck` carries deck metadata;
- each `slide ID "title" (...) """..."""` is analogous to a Beamer frame;
- a slide body is one ordered mixed Markdown/HTML/LaTeX/TikZ source stream;
- `note """..."""` is associated with the preceding slide and has the same
  mixed-source capability;
- SlideBlaster does not serialize every text or TikZ element into wrapper
  objects; native language syntax carries content, style, and geometry;
- parent/container parsing and mutations preserve mixed bodies exactly;
- the existing verified TikZ child projector may edit only admitted TikZ ranges;
  all other mixed/unsupported regions remain source-authoritative and read-only.

This is approval to implement and evaluate the bounded P0 trial, not yet a
permanent versioned-format or migration commitment. No silent conversion of
legacy documents is authorized.

### STR-007 refinement accepted — 2026-07-28 13:49 CEST

The product owner accepted the refined trial specimen in `temp/demo.slide`.
For this trial, each `slide` body is one implicit TikZ canvas containing any
number of TikZ nodes and paths. Node options carry native TikZ properties;
node bodies may contain exact mixed Markdown, HTML, and LaTeX source. Node IDs
are unique per slide audience surface and connectors resolve within that
surface. Direct invertible placements may be edited; relative, expanded,
ambiguous, and unsupported syntax remains exact read-only source. An associated
`note` is a separate mixed-content surface and identity namespace. This
refinement supersedes the earlier interpretation involving multiple explicit
`tikzpicture` islands inside a slide body.

## STR-008

- Received: `2026-07-28 14:54 CEST`
- Source: `product owner`
- Affects: `STR-007 browser workspace, navigator/carousel, direct manipulation`
- Disposition: `accepted corrective steering; active`

The product owner requires another UI pass informed by direct inspection of the
actual legacy SlideBlaster UI. The pass must remove implementation/debug copy,
replace the incorrect navigator treatment with the real product interaction
model, and reproduce/fix the real manual node-drag failure. Existing automated
smoke success is not sufficient evidence because the observed first-user path
still cannot move a node. New Slide and Undo/Redo are observed working and must
not regress. No broad feature expansion or additional diagnostic chrome is
requested.

## STR-009

- Received: `2026-07-29 11:54 CEST`
- Source: `product owner`
- Affects: `P0 acceptance boundary, integration timing, and the scope of continued work`
- Disposition: `accepted corrective steering; active as P0.1`

The product owner confirmed observation of the P0 artifact and judged it good.

The product owner did not authorize integration. Integration to `dev` is
explicitly withheld until a continuation, named `P0.1`, delivers the core TikZ
authoring breadth work: multiple named nodes on one slide, real node text and
structured content instead of identity placeholders, common node options
(anchors, text width, shape, fill, stroke, typography) where evidence supports
exact semantics, absolute and relative positioning with explicit writable or
read-only provenance, straight and orthogonal connectors with visible arrow tips,
connector geometry that follows an attached node, selection and movement of any
supported writable node, resize/create/duplicate/delete for the supported
subset, exact source-local edits with complete reparse and intended-semantic
verification, exact visibly read-only treatment of unsupported or ambiguous
TikZ, and a meaningful real-world fixture.

Consequences applied:

- P0 remains `active`; observation is recorded as `yes` and overall acceptance
  remains unanswered because further work is required before integration.
- P0.1 continues inside this session's existing worktree under one governed
  owner, so no second session duplicates ownership of the held TikZ,
  application, protocol, runtime, or host paths.
- The governing prompt for the continuation is
  `.META/sessions/SB2-20260729-001/.prompt`; that scaffold session stays
  unregistered and mutates nothing.
- No commit, integration, push, publication, deployment, or release is
  authorized by this steering entry.

## STR-010

- Received: `2026-07-29 14:13 CEST`
- Source: `product owner, answering the P0.1 scope questions in FEATURES-P0.1.md`
- Affects: `P0.1 delete semantics, unresolved connector meaning, resize modality, math rendering`
- Disposition: `accepted; binding on the P0.1 design and implementation`

1. **Feature set accepted.** The P0.1 feature list in `FEATURES-P0.1.md` is the
   agreed scope for the slice, subject to the three corrections below.

2. **Delete must remove a connected node.** The product owner rejected the
   proposed block: "deleting a connected node would just leave the arrow
   connector and the node it's connected to; nothing stops the removal of the
   original node." Therefore deleting a node removes exactly that node's authored
   statement. Its connectors remain in the authored source untouched, and an
   endpoint that no longer resolves must not blank or disable the document; it
   becomes a visibly unresolved read-only region naming the missing endpoint.

   This is the explicit product-owner decision required for design item `U1`. It
   supersedes the sentence in `docs/specs/str-007-implicit-canvas-slide-trial.md`
   that makes an unresolved admitted connector target turn the whole document
   syntax-only, and it supersedes the current `Deck.hs` behaviour. The integrator
   must amend that specification. Source bytes the user did not select are still
   never rewritten: delete removes only the selected node's statement span.

3. **Resize must be a drag.** The proposed discrete resize command was rejected:
   dragging a resize handle as one would expect is part of this slice and must not
   be downscoped, because this is a real product rather than a demonstration.
   Resize is therefore a pointer gesture on real selection handles, carrying the
   same verified-transaction, stale-rejection, atomic-failure, and exact-undo
   discipline as move. Design item `U3` is resolved against the discrete command.

4. **No partial math.** The product owner rejected preserving math as verbatim
   source with a "not typeset" marker: either do no math at all, or do the math
   fully. The orchestrator selected doing it properly: a declared TeX subset is
   really typeset through shared Haskell into a structured presentation-math
   projection that the browser paints, with no new external dependency, and any
   math construct outside that declared subset fails closed as an exact,
   visibly read-only preserved region rather than being partially rendered.

No commit, integration, publication, or release is authorized by this entry.
