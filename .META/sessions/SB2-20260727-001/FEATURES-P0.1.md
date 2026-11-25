---
status: proposed
updated: 2026-07-29
---

# P0.1 feature list for product-owner scope review

This is the exact feature set proposed for the P0.1 Core TikZ Authoring Breadth
slice, before implementation starts. Every entry is grounded in the original
SlideBlaster feature surface (`../editor`) or in an accepted contract in this
repository. Nothing here is invented; where grounding was missing, the item is
listed as excluded rather than guessed.

Authority: `DESIGN-P0.1.md` sections 1, 2, 7 and 14. Governing prompt:
`.META/sessions/SB2-20260729-001/.prompt`. Steering: `STR-009`.

## 1. Document and fixture

- One real-world demonstration deck, `event-ingest-review.slide`: an event-ingest
  architecture talk with two slides, 17 admitted nodes, 9 connectors, real prose,
  and deliberately unsupported regions.
- `demo.slide` and all its byte-exact laws stay untouched as P0 regression
  evidence.

## 2. Nodes on a slide

- Many named nodes per slide, each independently selectable.
- Absolute placement `at (x,y)`: writable and draggable.
- Relative placement `<side>=<dist> of <ref>` (`above`, `below`, `left`, `right`
  and the four diagonals), including nodes with no `at (...)` at all: resolved so
  they render in the right place, read-only for editing.
- `node distance=` as the relative gap default; `1/2` slide unit when absent.

## 3. Node content actually rendered

- Markdown: bold, italic, ordered lists, unordered lists, `\\` line breaks.
- LaTeX inline: `\textbf`, `\emph`, `\textit`, `\underline`, `\hl`.
- HTML (attribute-free): `b`, `strong`, `i`, `em`, `u`, `s`, `mark`, `div`, `span`.
- Math source `$...$` and `$$...$$` preserved and shown verbatim in a code
  container, with a visible "not typeset" marker. Math is not typeset in P0.1.
- Anything outside the subset makes that node's body an exact, visibly preserved
  read-only region; the node itself stays movable.

## 4. Node options honoured

- Anchors: the nine compass anchors.
- Sizing: `text width`, `minimum width`, `minimum height`, `minimum size`,
  `inner sep`, `inner xsep`, `inner ysep`.
- Shapes: rectangle, `rounded corners` (bare or with a length), `circle`,
  `ellipse`, `diamond`, `triangle`/`isosceles triangle`.
- Paint: `draw`, `draw=<colour>`, `fill=`, `color=`, `text=`, `opacity=`.
- Stroke: the seven named widths (`ultra thin` .. `ultra thick`), `line width=`,
  and the six dash patterns (`dashed`, `densely dashed`, `loosely dashed`,
  `dotted`, `densely dotted`, `loosely dotted`).
- Typography: the ten named font sizes, `\fontsize{a}{b}`, `\bfseries`,
  `\mdseries`, `\itshape`, `\upshape`.
- Lengths: no suffix, `cm`, `mm`, `pt`, `bp`, `in`, `em`, `ex`.
- Colours: the 17 xcolor base names with `c!p` and `c!p!d` mixing.
- `\tikzset{ name/.style={...} }` parsed and expanded where referenced, so
  authored styles actually render. The `\tikzset` block itself is read-only.

## 5. Connectors

- Straight `--` connectors.
- Orthogonal `-|` and `|-` connectors, with the corner derived at paint time from
  the resolved endpoints, so they reroute for free when a node moves.
- Endpoints as `(name)` or `(name.anchor)`, clipped to the real node outline so a
  line stops at the border instead of running to the box centre.
- Arrow tips: `to`, `latex`, `stealth`, `bar`, in `->`, `<-`, `<->`, `-stealth`
  and `-{Latex[...]}` spellings. An unknown tip is refused, not silently
  downgraded.
- Connector geometry follows an attached node during the drag preview and after
  commit.
- Stable connector identity across coordinate edits.

## 6. Editing operations

Each is one verified, undoable source transaction with exact no-op behaviour.

- Move: drag any writable node, with snapping, exact source-local coordinate
  rewrite, and exact undo.
- Resize: change `text width` / `minimum height` through a discrete accessible
  command.
- Create: insert a new node.
- Duplicate: copy a node with a derived identity.
- Delete: remove an unreferenced node.

## 7. Source authority

- Only the authored coordinate or length lexeme is rewritten. Comments,
  whitespace, option spelling and order, and every unrelated byte stay identical.
- Every edit reparses the complete affected source, verifies the intended
  semantic result, and verifies every other element in that slide is unchanged,
  before commit.
- Stale revision, stale paint, stale gesture, or stale measurement cannot commit.
- Failure is atomic: no source change, no history entry.
- Undo and redo restore exact bytes.

## 8. Unsupported TikZ made visible

Preserved byte-exactly, marked read-only, and listed with its location in a
source-notes panel so the user can find it:

- `\tikzset` style blocks, `\foreach` loops, `\begin{scope}` regions, `\path`.
- Computed coordinates such as `($...$)` and `([xshift=4mm]node.east)`.
- `to` and `bend` paths and path labels.
- Options recorded but not honoured, per node, with a reason.
- Node bodies outside the content subset.
- Notes surfaces.

## 9. Measurement

- Node box sizes come from real measurement of the rendered content by the
  browser, not from constants. Haskell owns all layout, boxes, ports and
  connector geometry; the browser only reports raw extents.
- When measurement is unavailable the canvas fails closed with a stated reason
  and paints no fabricated geometry. The editor does not blank.
- Native tests use an explicitly labelled nominal measurer that claims no
  typographic fidelity.

## Deliberately NOT in this slice

- Math typesetting.
- `style=<name>` theme roles, theme palette resolution, `\fontfamily`.
- Options recorded but not honoured: `align`, `rotate`, `scale`, `xshift`,
  `yshift`, `on grid`, `fit`, `label`, `overlay`, `stencil`, `fill opacity`,
  `draw opacity`, `line cap`, `line join`, `on background layer`.
- Shapes: `trapezium`, `parallelogram`, `regular polygon`, `cylinder`,
  `rounded rectangle`.
- Unit-bearing or polar `at` coordinates (read-only).
- Curved `.. controls ..` connectors; connector selection, creation, deletion or
  re-anchoring.
- Deleting a node that has connectors attached (blocked, not cascading).
- Resize by dragging a handle; resizing `minimum size` or a style-derived width.
- Multi-select and marquee.
- Re-anchoring by drag.
- `\begin{tikzpicture}` islands.
- Editing notes.

## Decisions requested

1. Is this the feature set you want for this slice?
2. Delete currently cannot remove a node that has connectors attached. Accept
   that limit for P0.1, or should connector deletion be added so any node can be
   deleted?
3. Resize is a discrete command rather than a drag handle. Accept, or is handle
   dragging required in this slice?
4. Math is preserved and shown verbatim but not typeset. Accept for P0.1?

---

## Amendment 2026-07-29 14:18: math decision corrected and scope reduced to what lands

Product-owner steering: building a full LaTeX renderer is rejected, and the
orchestrator must select the feature set it can actually land and then land it.

### Math: no math at all in this slice

The earlier proposal to typeset a declared TeX subset in shared Haskell is
withdrawn. There is no partial math and no hand-written LaTeX engine.

A node body containing math is treated as outside the content subset: its exact
bytes are preserved, the body is not painted, the node is marked visibly
read-only for content with a stated reason, and the node's coordinate remains
writable. This is the "no math at all" branch the product owner offered.

### Features being landed now

1. Real node option semantics: `text width`, `minimum width`, `minimum height`,
   `minimum size`, `inner sep`, `inner xsep`, `inner ysep`; shapes rectangle,
   `rounded corners`, `circle`, `ellipse`; paint `draw`, `draw=`, `fill=`,
   `text=`, `opacity=`; the seven named stroke widths and `line width=`; the six
   dash patterns; typography `font=` sizes with `\bfseries` and `\itshape`;
   lengths none, `cm`, `mm`, `pt`, `bp`, `in`, `em`, `ex`; the 17 xcolor base
   names with `c!p` and `c!p!d` mixing; and `\tikzset` style expansion.
2. Real node content painted on the canvas: Markdown bold, italic, ordered and
   unordered lists, `\\` breaks, and the attribute-free HTML subset. No math.
3. Real node boxes from real browser measurement of that content, failing closed
   with a stated reason when measurement is unavailable.
4. Connectors: straight `--` and orthogonal `-|` and `|-`, arrow tips `to`,
   `latex`, `stealth`, `bar`, endpoints clipped to the real node outline,
   geometry following a moved node, and identity stable across edits.
5. Relative positioning resolved for geometry and read-only for editing, with a
   visible reason, including nodes with no `at (...)`.
6. Unsupported and ambiguous TikZ made visible: unsupported statements,
   per-node unhonoured options, computed placements, `\tikzset`, `\foreach`,
   `scope`, and `to`/`bend` paths, each preserved byte-exactly and locatable.
7. The existing verified move, undo and redo continue to work unchanged.

### Deferred to the immediately following slice, not hidden

Resize by dragging a handle, create, duplicate, and delete. The product owner
has already ruled that resize must be a real handle drag and that delete must
remove a connected node while leaving its connector in place; both rulings stand
and are recorded in `STR-010` for that slice.
