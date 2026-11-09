# SlideBlaster Roadmap

This roadmap turns the complete product inventory in [FEATURES.md](FEATURES.md) into dependency-ordered, user-visible vertical slices.

It is a planning and status document, not an implementation specification, release authorization, or claim that represented code is usable.

## Status model

Each delivery slice uses exactly one delivery status:

- `queued` means the slice is prioritized but implementation has not started.
- `active` means one governed implementation session owns the slice.
- `blocked` means a named dependency or product-owner decision prevents progress.
- `locally-verified` means the agreed local automated and runtime checks passed at an exact revision.
- `ready-for-witness` means local evidence and reproducible demonstration instructions are ready for the product owner.
- `witnessed` means the product owner explicitly confirmed that they observed the artifact and behavior.
- `accepted` means the product owner separately confirmed that the observed behavior meets the intended outcome.
- `release-ready` means the accepted slice is integrated into `dev`, its release-relevant checks pass, and no named release blocker remains.
- `deferred` means the product owner explicitly agreed not to pursue the slice in the current release line.

A slice does not become `witnessed` because tests pass, and it does not become `accepted` merely because the product owner could open it.

## Working rules

1. Select the highest-priority `queued` slice whose dependencies are accepted or explicitly unnecessary for that slice.
2. Deliver one thin user-visible path through real source, application, adapter, and runtime boundaries rather than building disconnected foundations.
3. Give each implementation slice its own governed session and exact artifact, local demonstration, tests, review unit, and product-owner gates.
4. Run all work and demonstrations locally unless the product owner separately authorizes a networked integration or release operation.
5. Never publish, deploy, push, advance `main`, create a public release, or contact production services from roadmap execution.
6. Record local verification with the exact revision and commands before asking the product owner to witness the feature.
7. Ask separately whether the product owner observed the feature and whether it meets the intended outcome, then record both answers.
8. Keep rejected or changes-requested work open and return it to `active` with the requested behavior stated plainly.
9. Update the coverage ledger when a slice changes the actual executable product surface, not when types, files, or plans merely exist.
10. Treat source preservation, stale-edit rejection, atomic failure, and cross-runtime portability as gates for every affected slice.

## Release-candidate objective

The first release candidate is a locally runnable browser and native presentation editor in which a user can open or create a project, edit a multi-slide deck through source and canvas, save and reopen exact source, undo and redo edits, present the deck, and export portable output without data loss.

The release candidate is not published by this roadmap; publishing remains a later product-owner-authorized operation.

## Priority queue

| Priority | Slice | User-visible outcome | Depends on | Delivery status | Local evidence | Product-owner witness | Product-owner acceptance | Owning session |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| P0 | Source-authoritative editable browser canvas | The user opens exact source, drags a supported node, sees connected rendering update, and can undo without unrelated source changes. | None | `active` | Pending completion of the existing session. | Pending. | Pending. | `SB2-20260727-001` |
| P1 | One real application model in the browser shell | Source, history, selection, command enablement, diagnostics, and canvas paint come from one long-lived Haskell application model rather than parallel host state. | P0 | `queued` | Pending. | Pending. | Pending. | Unassigned. |
| P2 | Local project create, open, save, and reopen | The user creates or opens a local project, edits it offline, saves exact bytes conditionally, reloads, and sees the same deck and history boundary. | P1 | `queued` | Pending. | Pending. | Pending. | Unassigned. |
| P3 | General multi-slide deck render | The user opens a supported multi-slide document and sees every slide rendered in order with stable identities, diagnostics, and source-linked selection. | P1, P2 | `queued` | Pending. | Pending. | Pending. | Unassigned. |
| P4 | Continuous deck and structure editing | The user scrolls a continuous editable deck, navigates with synchronized thumbnails, and can insert, delete, duplicate, reorder, undo, and redo slides. | P3 | `queued` | Pending. | Pending. | Pending. | Unassigned. |
| P5 | Core canvas authoring | The user creates, selects, moves, resizes, deletes, duplicates, and reorders supported nodes and connectors through verified source transactions. | P3, P4 | `queued` | Pending. | Pending. | Pending. | Unassigned. |
| P6 | Inline mixed-content editing | The user edits supported Markdown, LaTeX, and safe HTML content directly on the canvas while preserving construct provenance and unrelated source. | P5 | `queued` | Pending. | Pending. | Pending. | Unassigned. |
| P7 | Properties, shapes, snapping, and themes | The user inserts core shapes, edits geometry and visual properties, uses deterministic snapping, and applies structured theme roles and furniture. | P5, P6 | `queued` | Pending. | Pending. | Pending. | Unassigned. |
| P8 | Overlay preview and live presenter | The user authors and previews fixed-geometry build steps, adds synchronized speaker notes, and drives local audience and presenter windows from one cursor. | P3, P6 | `queued` | Pending. | Pending. | Pending. | Unassigned. |
| P9 | Honest local export | The user exports self-contained HTML, print-ready PDF through an explicit local capability, and a safe workspace archive with target-specific diagnostics. | P3, P7, P8 | `queued` | Pending. | Pending. | Pending. | Unassigned. |
| P10 | Native local parity | The user performs the accepted project, editing, presenting, and export paths in the native application against a real local working copy. | P2 through P9 | `queued` | Pending. | Pending. | Pending. | Unassigned. |
| P11 | Release-candidate hardening | Browser and native paths meet source-safety, accessibility, performance, recovery, security, documentation, and cross-target conformance gates. | P0 through P10 | `queued` | Pending. | Pending. | Pending. | Unassigned. |
| P12 | User-owned Git synchronization | The user initializes or connects a repository, sees sync state, commits, pulls, pushes, and resolves divergence without losing portable Markdown history. | P2, P11 | `queued` | Pending; local Git remotes only until separately authorized. | Pending. | Pending. | Unassigned. |
| P13 | Authenticated GitHub synchronization | The user grants one repository and syncs with short-lived, repository-scoped credentials through the accepted security boundary. | P12 and explicit authorization for networked testing | `queued` | Local mocks first; live integration requires a separate user gate. | Pending. | Pending. | Unassigned. |
| P14 | Best-effort live collaboration | A small invited group edits one deck live with visible presence, owner-anchored persistence, and explicit degraded-state reporting. | P12, P13 | `queued` | Local multi-client test environment only by default. | Pending. | Pending. | Unassigned. |
| P15 | Reliable collaboration and commercial modules | Authorized users exercise server-authoritative collaboration, managed storage, team controls, and capability-gated billing behavior. | P14 and separate product/service decisions | `queued` | Local service stack only until deployment is explicitly authorized. | Pending. | Pending. | Unassigned. |

## Feature-area coverage ledger

This ledger summarizes the 201 detailed requirements in `FEATURES.md`; a feature area remains incomplete until its applicable requirements are executable through the product and accepted by the product owner.

| `FEATURES.md` area | Main delivery slices | Coverage status | Evidence or gap |
| --- | --- | --- | --- |
| Product and platform | P10, P11, P15 | `partially-represented` | Shared runtime boundaries exist, but complete browser and native product parity is not locally accepted. |
| Workspace and application shell | P1, P4 | `partial` | A bounded browser shell exists, but the general application model and enabled command surface are not complete. |
| Projects, files, and durable source | P0, P2, P12 | `active` | Exact-source laws and a bounded path exist; general local projects and full format coverage remain queued. |
| Deck structure and navigation | P3, P4 | `represented` | Deck types exist, but the complete continuous editable deck and structure operations are not locally accepted. |
| Canvas interaction and geometry | P0, P5, P7 | `active` | One bounded move path is active; general selection, gestures, and property projection remain queued. |
| Connectors, groups, and diagrams | P5, P7 | `partial` | Semantic connector and group concepts exist without a complete authoring surface. |
| Shapes, assets, and creation | P7 | `partial` | Catalog and outline data exist without the complete creation and asset workflow. |
| Object properties and styling | P6, P7 | `represented` | Property semantics exist without complete browser editing and verified source projection. |
| Rich and mixed-language content | P6 | `represented` | Content types exist without the complete reader, renderer, inline editor, and inverse path. |
| Themes, layouts, and furniture | P7 | `represented` | Theme semantics exist without an accepted theme authoring and rendering path. |
| Overlays and animation | P8, P9 | `represented` | Overlay and animation semantics exist without complete local playback and export behavior. |
| Speaker notes and presenting | P8 | `represented` | Presenter state exists without accepted local audience and console windows. |
| Rendering, accessibility, and performance | P3, P7, P11 | `partial` | Render-plan semantics exist; the general layered renderer, accessibility pass, and scale gates remain. |
| Export and interchange | P9 | `partial` | Planning and some deterministic writers exist without complete local execution and product-owner acceptance. |
| Local storage, Git, and synchronization | P2, P12, P13 | `partial` | Native storage and limited browser capabilities exist; full working-copy and remote workflows remain. |
| Real-time collaboration | P14, P15 | `planned` | Accepted design exists, but collaboration is outside the current executable local core. |
| Identity, security, billing, and administration | P13, P15 | `planned` | Accepted architecture exists, but services and commercial controls are not current local product capabilities. |
| Reliability, portability, and quality | Every slice, especially P11 | `continuous` | Every slice must add and retain its applicable verification evidence. |

## Product-owner witness record

For every slice that reaches `ready-for-witness`, append one row after the demonstration is offered.

| Slice | Revision | Local access instructions | Observation asked and response | Acceptance asked and response | Resulting status | Date |
| --- | --- | --- | --- | --- | --- | --- |
| None yet. | — | — | — | — | — | — |

## Local release-readiness gate

A candidate may be described as locally release-ready only when all of the following are true:

- P0 through P11 are `accepted` or explicitly `deferred` by the product owner with no contradiction in the release objective.
- The exact candidate revision is integrated into `dev` and the worktree is clean except for explicitly documented local records.
- Focused, package, native, Wasm, browser, cross-target, accessibility, recovery, and end-to-end checks applicable to the candidate pass locally.
- Browser and native demonstrations use packaged artifacts rather than development-only substitute paths.
- `VERSION`, package versions, changelog, user documentation, licenses, third-party notices, and reproducible build instructions are internally consistent.
- No unresolved source-safety, data-loss, credential, sandbox, archive, or release-blocking diagnostic remains.
- The product owner has witnessed and accepted the complete release-candidate workflow separately from individual feature demonstrations.

## Prose-only publication plan

Publication is deliberately outside this roadmap’s authority and requires a new explicit product-owner instruction.

After a candidate becomes locally release-ready, the release operator would present the exact `dev` revision, complete local evidence, known limitations, proposed version, changelog text, and artifact inventory for product-owner review; obtain explicit authorization for any network access, signing, upload, deployment, or repository push; build and verify release artifacts in the approved environment; stage a private preview if authorized; obtain final product-owner acceptance of that exact candidate; fast-forward `main` locally only under the release runbook; create signed release artifacts and deployment records only if separately authorized; and report every resulting URL, checksum, revision, rollback path, and unresolved risk without treating publication as session closure.
