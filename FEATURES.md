# SlideBlaster Features

This inventory describes the capabilities SlideBlaster as a complete product needs, regardless of their current implementation status.

## Product and platform

- SlideBlaster must provide a full presentation editor in both a modern web browser and a native desktop application.
- SlideBlaster must use the same document semantics, editing laws, rendering behavior, and export policy across browser and desktop clients.
- SlideBlaster must support complete offline creation, editing, local history, and export wherever the selected operation has no unavoidable network dependency.
- SlideBlaster must keep platform-specific storage, Git, windowing, compilation, and download behavior behind explicit runtime capabilities.
- SlideBlaster must fail clearly when a runtime capability is unavailable rather than silently substituting weaker behavior.
- SlideBlaster must offer a free tier with the complete editor, offline use, user-owned storage, asynchronous Git collaboration, and best-effort live collaboration.
- SlideBlaster must support optional paid capabilities for reliable multiplayer collaboration, managed private storage, and team workspaces.
- SlideBlaster should eventually support enterprise identity, administration, billing, and self-hosted deployment without changing the document model.

## Workspace and application shell

- SlideBlaster must open into a canvas-first workspace with independently controllable Files, Source, Shapes, History, Navigator, Properties, and notes surfaces.
- SlideBlaster must preserve pane visibility, pane size, active tool, active selection, and zoom choices across ordinary workspace interactions and reloads.
- SlideBlaster must keep hidden pane contents mounted when practical so temporary layout changes do not discard user state.
- SlideBlaster must display the application identity and current document title consistently in the top bar.
- SlideBlaster must group top-bar controls by workspace views, history, insertion, formatting, presentation, and export.
- SlideBlaster must keep selection-sensitive formatting controls visible but disabled when no editable target exists.
- SlideBlaster must expose Present as the single primary top-bar action and collect output operations in one Export menu.
- SlideBlaster must collapse lower-priority formatting controls before identity, Present, or Export when horizontal space is limited.
- SlideBlaster must expose stable disabled reasons for commands that cannot currently run.
- SlideBlaster must support keyboard operation and accessible names for all essential workspace commands.
- SlideBlaster must provide reusable, accessible, resizable popup surfaces for substantial tools such as theme editing.
- SlideBlaster must provide a project landing surface for recent projects and curated examples or compatibility benchmarks.

## Projects, files, and durable source

- SlideBlaster must create, open, rename, save, close, and reopen presentation projects without losing authored data representation.
- SlideBlaster must represent a presentation as portable, human-readable source files and ordinary assets in a user-controlled working copy.
- SlideBlaster must treat the exact authored source text/bytes and their revision as the durable source of truth.
- SlideBlaster must preserve comments, whitespace, delimiters, unsupported constructs, malformed regions, and every unrelated byte during a local edit.
- SlideBlaster must reject stale edits whose source revision no longer matches the revision from which the edit was derived.
- SlideBlaster must make failed source projection atomic so source, canvas state, and history remain unchanged.
- SlideBlaster must commit a canvas-derived edit only after reparsing the candidate source and verifying that it expresses the intended semantic result.
- SlideBlaster must keep expanded, ambiguous, or unsupported syntax read-only until an explicit and verified inverse edit rule exists.
- SlideBlaster must never canonicalize an entire document as a side effect of an ordinary local edit.
- SlideBlaster must keep malformed source editable while retaining the last valid rendering in a visibly stale and non-editable state.
- SlideBlaster must attach actionable diagnostics to precise source, slide, object, property, content, animation, asset, or workspace locations.
- SlideBlaster must support exact source editing in a dedicated source pane with revision-safe synchronization to every visual surface.
- SlideBlaster must support undo and redo over source snapshots while suppressing no-op history entries and clearing redo branches after divergent edits.
- SlideBlaster must preserve stable identities for slides, canvas objects, surfaces, and source-backed constructs across edits whenever their source identity survives.
- SlideBlaster must support reusable standalone TikZ figure files through the same source-authoritative editing pipeline as presentation slides.
- SlideBlaster must offer an explicit compiled view-only mode for figures that require a full TikZ engine beyond the editable subset.
- SlideBlaster must label compiled figure mode as read-only and fail loudly when its selected compilation engine cannot render the source.

## Deck structure and navigation

- SlideBlaster must represent every presentation as a non-empty ordered deck with stable slide identities, titles, dimensions, and aspect ratio.
- SlideBlaster must show the entire deck as one continuous vertically scrolling canvas whose slides remain editable in place.
- SlideBlaster must provide a synchronized thumbnail carousel that tracks the active slide and can scroll the canvas to a selected slide.
- SlideBlaster must visually center and emphasize the active slide in the thumbnail carousel.
- SlideBlaster must insert a new slide immediately after the active slide from either the top bar or the navigator.
- SlideBlaster must delete the active slide when no nested object owns the delete command while preventing deletion of the deck’s final slide.
- SlideBlaster must reorder slides by dragging thumbnails and propagate the resulting order consistently to source, canvas, presenter, and exports.
- SlideBlaster must make slide insertion, deletion, duplication, and reordering undoable source transactions.
- SlideBlaster must support keyboard navigation to previous, next, first, and last slides without hijacking keys used by a focused text editor.
- SlideBlaster must support rotating an individual slide without changing the orientation or coordinate meaning of other slides.
- SlideBlaster must remain usable for large decks through bounded rendering, virtualization, or equivalent performance controls that preserve editing semantics.

## Canvas interaction and geometry

- SlideBlaster must render each slide as an ordered collection of semantic objects with deterministic z-order and explicit ordering barriers.
- SlideBlaster must support selecting one object, multiple objects, connector handles, and ranges of editable content.
- SlideBlaster must support moving, resizing, rotating, deleting, duplicating, grouping, ungrouping, and reordering compatible canvas objects.
- SlideBlaster must preview pointer gestures without mutating durable source and commit each completed gesture as one verified undoable edit.
- SlideBlaster must support absolute placement and source-expressed relative placement without silently changing one mode into the other.
- SlideBlaster must resolve relative placement dependencies deterministically and report cycles or unresolved references clearly.
- SlideBlaster must provide grid snapping, alignment guides, equal-spacing guides, theme anchors, and relative bindings during movement.
- SlideBlaster must prioritize explicit bindings over alignment, spacing, and grid suggestions in a stable and documented order.
- SlideBlaster must allow a modifier key to bypass snapping and binding for precise free movement.
- SlideBlaster must provide pan and validated zoom controls while preserving a stable slide-space coordinate system.
- SlideBlaster must support direct numeric editing of position, size, rotation, scale, and other geometric properties.
- SlideBlaster must provide visible selection bounds, resize handles, rotation affordances, connector handles, and hit targets without contaminating exported output.
- SlideBlaster must keep stale or unsolicited paints from replacing a newer rendering of any slide or notes surface.
- SlideBlaster must make canvas hit testing, focus order, and interaction labels available to assistive technologies.

## Connectors, groups, and diagrams

- SlideBlaster must create connectors between explicit object anchors and preserve their semantic endpoints when connected objects move.
- SlideBlaster must support straight, orthogonal, and cubic connector paths with configurable ports and arrow tips.
- SlideBlaster must expose connector stroke, width, dash, color, endpoint, routing, and arrow-tip properties.
- SlideBlaster must provide an explicit connector tool whose active state is visible and cancellable with Escape.
- SlideBlaster must support grouped objects with stable child order and source-preserving group edits.
- SlideBlaster must distinguish visual grouping from layout containers so containment behavior is never inferred accidentally.
- SlideBlaster must support diagram edits without flattening semantic nodes and connectors into anonymous drawing primitives.

## Shapes, assets, and creation

- SlideBlaster must provide an on-canvas creation menu for text, shapes, connectors, images, tables, groups, and other supported object types.
- SlideBlaster must provide a searchable Shapes pane with a curated core palette and a larger attributed stencil catalog.
- SlideBlaster must insert catalog items as ordinary editable canvas objects rather than retaining hidden catalog-specific runtime behavior.
- SlideBlaster must support rectangles, rounded rectangles, ellipses, arcs, polygons, paths, compound outlines, custom geometry, and resolved stencil geometry.
- SlideBlaster must preserve unresolved or unsupported stencil references without pretending they are editable geometry.
- SlideBlaster must retain attribution, license, source revision, and provenance for imported stencil libraries and generated shape packs.
- SlideBlaster must import images, fonts, figures, and other assets as exact resources with stable project-relative references.
- SlideBlaster must report missing, unreadable, unsupported, or mismatched assets without discarding their source references.
- SlideBlaster must support reusable figures and project assets without requiring proprietary binary containers.
- SlideBlaster must provide a closed resource manifest for rendering and export so every required byte is known before an artifact is produced.

## Object properties and styling

- SlideBlaster must expose fill, stroke, width, dash, opacity, corner, gradient, shadow, scale, flip, and transform properties where the selected object supports them.
- SlideBlaster must expose typography controls for font family, font size, weight, emphasis, decoration, color, highlight, alignment, wrapping, and line spacing.
- SlideBlaster must apply formatting to the active text selection when editing inline and to the whole selected node when no text range is active.
- SlideBlaster must route property changes according to whether the target is a node, connector, group, content range, slide, notes surface, or theme role.
- SlideBlaster must preserve explicit source properties while resolving inherited defaults from themes, roles, and creation presets.
- SlideBlaster must use a deterministic precedence from fallback values through theme and role defaults to preset patches, overrides, and explicit properties.
- SlideBlaster must make unsupported or source-ambiguous properties visible but read-only rather than dropping them.
- SlideBlaster must treat a property edit that changes no semantic value as a no-op rather than creating source or history churn.

## Rich and mixed-language content

- SlideBlaster must support recursively mixed Markdown, LaTeX, and safe HTML content within canvas nodes.
- SlideBlaster must preserve the source dialect and provenance of every editable content construct during visual edits.
- SlideBlaster must support paragraphs, text marks, links, code, lists, images, math, citations, tables, columns, matrices, and nested content containers.
- SlideBlaster must render mathematical content faithfully while preserving its opaque authored source when no safe inverse edit exists.
- SlideBlaster must support inline content editing directly on the rendered canvas without replacing unrelated node source.
- SlideBlaster must allow a raw construct editor to open over the exact source-backed construct under the pointer.
- SlideBlaster must support live editing shortcuts such as Markdown list creation only when they can be projected deterministically to source.
- SlideBlaster must resolve citations and bibliographies consistently across the audience deck and exports without allowing private notes to renumber audience citations.
- SlideBlaster must resolve includes and linked assets through the workspace while preserving clear loading, failure, and stale states.
- SlideBlaster must sandbox or reject unsafe raw HTML and prevent authored content from escaping its rendering boundary.
- SlideBlaster must surface unsupported content as a precise hard error or explicit opaque read-only region rather than rendering a misleading approximation.

## Themes, layouts, and furniture

- SlideBlaster must represent each theme as structured style defaults, master layout regions, and reusable slide furniture.
- SlideBlaster must provide palettes, type scales, spacing values, semantic roles, and per-role object defaults.
- SlideBlaster must provide relative master regions that guide placement without silently owning or rewriting an object’s explicit coordinates.
- SlideBlaster must expose theme regions and guides as snapping targets during canvas editing.
- SlideBlaster must support safe areas and reusable logos, headers, footers, page numbers, backgrounds, and other furniture.
- SlideBlaster must render theme furniture consistently in the editor, presenter, standalone HTML, PDF, and applicable source exports.
- SlideBlaster must let users create, inspect, edit, save, import, switch, and share themes as ordinary project files.
- SlideBlaster must package theme assets with the project so themes survive Git sync, workspace export, and offline use.
- SlideBlaster must preserve explicit slide and object choices when a theme changes unless the source explicitly delegates those choices to the theme.

## Overlays and animation

- SlideBlaster must support Beamer-style overlay specifications that reveal whole objects or inline content on derived presentation steps.
- SlideBlaster must support pause markers and bounded or open step ranges while preserving their authored source form.
- SlideBlaster must resolve overlay visibility without reflow by measuring maximal content once and reserving geometry for hidden content.
- SlideBlaster must provide a contextual build-step preview control near the canvas rather than placing it in the global top bar.
- SlideBlaster must export overlay steps as distinct beats or pages while reusing one resolved layout for the slide.
- SlideBlaster must support entrance, emphasis, exit, motion, and slide-transition animations.
- SlideBlaster must support opacity, translation, rotation, scale, fill, stroke, and motion-path animation tracks.
- SlideBlaster must support frame, step, with, after, and direct-interaction triggers with deterministic scheduling.
- SlideBlaster must support duration, delay, easing, repeat, direction, and fill behavior for timed animations.
- SlideBlaster must validate that every animation target belongs to its scene and that every keyframe sequence is coherent.
- SlideBlaster must honor reduced-motion preferences through an explicit reduced-motion disposition rather than merely slowing animations.
- SlideBlaster must classify unsupported animation fidelity per export target and let policy either warn, approximate explicitly, or reject the export.

## Speaker notes and presenting

- SlideBlaster must let every slide carry an optional full-canvas speaker-notes sidecar with the same content and overlay capabilities as an audience slide.
- SlideBlaster must show audience and notes canvases together while authoring and address edits to the correct surface.
- SlideBlaster must drive audience overlays and speaker notes from one step counter owned by the audience slide.
- SlideBlaster must warn about notes content staged beyond the audience slide’s final step and must not create extra audience clicks for it.
- SlideBlaster must open a fullscreen-capable audience window and a separate presenter console from the current in-memory deck.
- SlideBlaster must keep audience and presenter windows synchronized through one ordered cursor over slide-and-step beats.
- SlideBlaster must allow navigation from either presentation window using next, previous, first, and last commands.
- SlideBlaster must show current slide and step counters, elapsed time, current notes, and a next-slide preview in the presenter console.
- SlideBlaster must render audience, notes, thumbnails, and exports through the same semantic rendering pipeline.
- SlideBlaster should support remote control, a laser pointer, temporary annotation, and notes-inclusive handouts as presenter extensions.

## Rendering, accessibility, and performance

- SlideBlaster must render editable presentations with layered vector geometry, ordinary HTML content, and a separate interaction overlay in one shared coordinate space.
- SlideBlaster must use measured structured content and exact font and resource readiness when resolving layout.
- SlideBlaster must fail closed when a measurement backend cannot honor structured content, width, font, or resource requirements.
- SlideBlaster must produce a closed layered render plan with stable identities, z-order, interaction metadata, resources, and animation bindings.
- SlideBlaster must render the same accepted semantic scene consistently across editor, thumbnails, presenter, standalone HTML, and print output.
- SlideBlaster must provide semantic labels, decorative markers, logical focus order, and sufficient contrast for rendered and interactive content.
- SlideBlaster must support native text selection and standard browser editing behavior where doing so does not violate source authority.
- SlideBlaster must cache and incrementally recompute measurement, layout, and rendering without allowing stale results to win.
- SlideBlaster must remain responsive during large-deck editing, complex diagrams, asset loading, source analysis, and collaboration updates.
- SlideBlaster must never sacrifice exact source preservation or semantic verification as a performance optimization.

## Export and interchange

- SlideBlaster must export a deterministic self-contained HTML presentation that can be viewed offline without SlideBlaster services.
- SlideBlaster must export rendered PDF through an explicit browser or native print capability using the same visual surface as the editor.
- SlideBlaster must export a deterministic LaTeX or Beamer project for best-effort downstream editing without misrepresenting it as pixel-identical output.
- SlideBlaster must export standalone TikZ figures for supported editable figure documents.
- SlideBlaster must export and import the complete working copy as a safe deterministic archive containing source, themes, assets, and required metadata.
- SlideBlaster must preserve slide order, overlay beats, notes policy, themes, resources, and supported animations in every applicable export target.
- SlideBlaster must analyze each export for unsupported constructs and report target-specific warnings or fatal incompatibilities before writing an artifact.
- SlideBlaster must never emit placeholder bytes and call them a successful PDF, archive, compiled figure, or other artifact.
- SlideBlaster must prevent unsafe archive paths, missing resources, accidental external dependencies, and non-deterministic file ordering.
- SlideBlaster must provide downloads in the browser and ordinary filesystem writes in the desktop application through equivalent export requests.
- SlideBlaster must keep all user-owned source and assets recoverable with standard tools even if SlideBlaster is unavailable.

## Local storage, Git, and synchronization

- SlideBlaster must maintain a local working copy in browser storage or the native filesystem so editing can continue offline.
- SlideBlaster must ensure storage and Git operations observe the same working-copy bytes and directory structure.
- SlideBlaster must support Git repository initialization, cloning, status, staging, committing, history, pulling, and pushing.
- SlideBlaster must show whether the working copy is clean, modified, committing, pulling, pushing, offline, diverged, conflicted, or waiting for persistence.
- SlideBlaster must store free-user projects in repositories owned by the user and must not require SlideBlaster to custody presentation files.
- SlideBlaster must pull on appropriate open or focus boundaries and push on explicit commit or safe idle boundaries without hiding failures.
- SlideBlaster must support asynchronous collaboration through ordinary Markdown commits and standard Git history.
- SlideBlaster must preserve locality in serialized source so edits to different elements usually auto-merge as disjoint Git changes.
- SlideBlaster must enter an explicit conflict mode and suspend canvas editing when unresolved Git markers make the document invalid.
- SlideBlaster must provide an in-app browser conflict editor with ours, theirs, keep-both, manual-edit, reparse, commit, and push workflows.
- SlideBlaster must let desktop users resolve conflicts with external Git tools and automatically resume once clean source reparses.
- SlideBlaster must let browser users preserve both divergent tips on a work-in-progress branch for resolution elsewhere.
- SlideBlaster must support managed private repositories as an optional storage provider without changing presentation semantics.

## Real-time collaboration

- SlideBlaster must support live multi-user editing over the same structured presentation model used by solo editing.
- SlideBlaster must seed an ephemeral collaboration document from source at session start and materialize verified source from it at commit time.
- SlideBlaster must keep the collaboration state session-scoped and use Git source rather than a persisted CRDT as durable history.
- SlideBlaster must merge ordinary text character by character, lists structurally, and geometry or style independently per property.
- SlideBlaster must stream cursors, selections, peer presence, and live drag previews through ephemeral awareness state.
- SlideBlaster must commit only the final semantic placement at the end of a collaborative drag and must not require object locks.
- SlideBlaster must offer best-effort peer-to-peer sessions for small groups with owner-anchored persistence.
- SlideBlaster must clearly warn peers when the owner is absent and a peer-to-peer session is no longer being persisted.
- SlideBlaster must offer reliable server-authoritative sessions with reconnection, crash safety, larger groups, and a single repository writer.
- SlideBlaster must allow owners to invite specific authenticated users with session-scoped authorization.
- SlideBlaster must optionally allow an explicit lower-security link invitation whose possession grants access only to that session.
- SlideBlaster must show peer, connection, persistence, and Git synchronization status throughout a live session.
- SlideBlaster must reconcile remote session changes with revision fencing, paint fencing, local history policy, and source-preserving projection.

## Identity, security, billing, and administration

- SlideBlaster must authenticate users through GitHub for user-owned repository access while keeping editing available offline after authentication expires.
- SlideBlaster must request access only to repositories the user explicitly selects through a revocable GitHub App installation.
- SlideBlaster must mint short-lived single-repository contents-only credentials on demand and keep them only in client memory.
- SlideBlaster must keep durable signing keys in isolated KMS or HSM custody and restrict signing access to a minimal token-minting service.
- SlideBlaster must authorize every token mint against the requesting identity and selected repository to prevent confused-deputy access.
- SlideBlaster must use secure web cookies with CSRF protection and native operating-system keychain storage for durable session credentials.
- SlideBlaster must verify revocation webhooks, expire affected sessions, rotate secrets, rate-limit minting, and avoid logging credentials.
- SlideBlaster must protect browser Git traffic with a first-party hardened non-logging path whenever a CORS proxy is unavoidable.
- SlideBlaster must enforce a strict content security policy and sandbox authored HTML, exported content, and compilation boundaries.
- SlideBlaster must map billing products to stable account capability flags so packaging can change without changing editor semantics.
- SlideBlaster must support owner-paid premium sessions in which invited collaborators can participate without individual subscriptions up to a configured cap.
- SlideBlaster must support organization membership, roles, permissions, and shared libraries as a team-workspace capability.
- SlideBlaster should support enterprise single sign-on, administrative controls, consolidated billing, auditability, and self-hosted deployment.

## Reliability, portability, and quality

- SlideBlaster must preserve user data ahead of convenience, visual polish, performance, or delivery deadlines.
- SlideBlaster must produce deterministic parsing, semantic analysis, rendering plans, source projection, and export artifacts for identical inputs.
- SlideBlaster must keep shared product logic portable across native GHC and GHC WebAssembly runtimes.
- SlideBlaster must isolate browser-only and native-only dependencies from the shared semantic core.
- SlideBlaster must verify source-edit laws, rendering behavior, protocol behavior, exports, and adapter capabilities with automated tests at appropriate boundaries.
- SlideBlaster must verify cross-client render and export parity before claiming browser and desktop feature parity.
- SlideBlaster must expose structured diagnostics and capability failures instead of relying on logs or silent degradation.
- SlideBlaster must use versioned closed protocols between the semantic application and runtime hosts.
- SlideBlaster must reject unknown commands, malformed payloads, mismatched revisions, stale tickets, and unsolicited runtime completions safely.
- SlideBlaster must keep user documents portable, diffable, mergeable, and recoverable without proprietary services or databases.
- SlideBlaster must provide clear documentation for supported syntax, editable subsets, read-only fallbacks, export fidelity, and known limitations.
- SlideBlaster must meet accessibility, security, performance, offline, and data-recovery expectations before public release.
