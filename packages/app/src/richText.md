# WYSIWYG editing surface (richText.ts)

Style-in-place (ADR 0014's first canvas-editing affordance): the model <-> editable-DOM
seams behind the rich inline editor ([canvas.ts](./canvas.md) mounts it), plus the live
typing behaviors. Normative dialect rules: `design/format/node-content.md`; UX spec:
`design/ux/style-in-place.md`.

## Contract

- **`editableHtml(content, atoms) -> html`** — a NodeContent rendered for _editing_:
  like the engine render but stamping what the render omits. Style runs become semantic
  elements (`strong/em/u/s`, or the html run's own span/div) carrying their exact run
  identity in `data-run` (`latex:textbf`, `md:**`, `html:b`, …) — provenance the DOM
  can round-trip. Math becomes an **atomic island** (`.rt-atom.rt-math`,
  `contenteditable="false"`) typeset by the shared `renderOptions.renderMath` (KaTeX)
  and carrying its source in `data-tex`/`data-display` (KaTeX HTML drops it). Lists are
  real `ul/ol` (`data-run="list:<dialect>"`, `li[data-spec]`) — natively editable.
  Every other construct (columns, matrix, table, overlay, fragment, image, include,
  cite, citefootnote, printbibliography) freezes as an indexed island
  (`data-atom="i"` into the caller-held `atoms` registry) showing its rendered preview
  (a render-invisible `\pause` shows a source chip instead, so no caret trap).
- **`readEditable(root, atoms) -> NodeContent`** — the inverse walk. `data-run`
  elements rebuild their exact run kind (provenance preserved; execCommand splits clone
  attributes, so split fragments stay provenance-true); `data-atom` islands return the
  original run object verbatim; **bare** `b/strong/i/em/u/s/strike` and positively
  styled spans (browser-authored styling) become html-dialect runs — the documented
  default dialect for new canvas content (`strike` canonicalizes to `s`;
  whitespace-only wrappers unwrap; negation styles have no model form and unwrap).
  Tolerances: `<br>`/`<div>` line shapes read as `\n` (`<div><br></div>` = one empty
  line; a trailing `<br>` is Chromium's placeholder, stripped — a genuine trailing
  newline survives, so a no-op close stays byte-identical), ZWSP anchors strip, NBSP
  normalizes, fragmented text nodes merge, unknown elements unwrap (the sanitization
  boundary together with plain-text paste). Whitespace-only -> `empty`.
- **`wireRichEditing(editor)`** — the live behaviors, IME-safe (bail while composing),
  with every programmatic mutation routed through `execCommand` so the **native undo
  stack stays coherent** (Ctrl+Z after a conversion restores the literal typed source):
  - `$…$` / `$$…$$` converts to a math island when the closing `$` is typed;
    `\textbf{`/`\emph{`/`\textit{`/`\underline{` converts the moment `{` completes —
    an empty styled element with the caret _inside_ (live "you are in bold" tracking),
    and `}` exits past it (brace consumed); `**…**`/`*…*` convert on the closing
    marker with `md` provenance. Scans never cross a text-node boundary.
  - Backspace after a math island re-opens it as its `$…$` source (caret at end);
    after any other island it selects it first, deleting whole on the second press.
    Chromium reports the doomed island via `getTargetRanges()` in shapes that vary
    (lone ZWSP anchor / a range spanning the neighbour text nodes) — `islandBehindBackspace`
    normalizes them.
  - Paste and drop land as plain text; islands are not draggable; clicking an island
    selects it whole.
- **`padIslands(root)`** — ZWSP caret anchors where Chromium cannot otherwise place a
  caret (parent start/end, between adjacent islands). Re-run after island surgery.
- **`ZWSP`** — the anchor character; editor-only, stripped on read.

## Invariants

- `readEditable(mount(editableHtml(c, atoms)), atoms)` serializes byte-identical to `c`
  for untouched content (atoms guarantee it for opaque runs; reconstructive
  `serializeBody` guarantees it for style runs and canonical lists).
- Only in-subset runs are ever produced, so a WYSIWYG commit can't create ADR-0015
  error content.
- The commit is one NodeContent transform fired by the caller (`editContentModel`,
  ADR 0016); this module never talks to the controller.
