---
status: proposed
updated: 2026-11-06
---

# slideBlaster Markdown deck format (alpha)

This specifies `*.slideBlaster.md` as read by `slideblaster-deck`, the block
layer in `slideblaster-syntax`, and the flow lowering in
`slideblaster-canvas`. The design is `docs/architecture/alpha.md` section 3.
The deck is lossless: the exact UTF-8 bytes are authoritative, the syntax is a
set of spans, and meaning is derived and never printed back.

## Container

A deck is `frontmatter? preamble-text? slide*`.

- Frontmatter is a block between two lines containing only `---`, starting at
  byte 0. It is a YAML subset: `key: value` (plain, double-quoted, single-quoted),
  `|` and `>` block scalars, and `- item` lists. Keys the alpha defines are
  `slideblaster`, `title`, `subtitle`, `authors`, `institute`, `date`, `theme`,
  `aspect` (`W:H`, default `16:9`), `bibliography`, `citation-style`,
  `preamble`, `listing-defaults`, `routes` and `sectionSlides`. Other keys are kept and reported with an
  information diagnostic.
- A slide starts at a column-0 line `## Title {#id}` outside fenced code and runs
  to the next such line. The id matches `[a-z0-9][a-z0-9-]*` and is unique. A
  slide without `{#id}` gets an implicit `slide-N` (the first unused number); it
  is not written until a writer sets it.
- A title slide with id `title-slide` is generated from the frontmatter title,
  subtitle, authors, institute and date. A `# Title` line before the first slide
  overrides the frontmatter title. It is not editable, movable or deletable.

Container-level failures make the document syntax-only with a hard diagnostic:
invalid UTF-8, unclosed frontmatter, malformed or duplicate ids, unusable
aspect, no slides. Nothing inside a slide body is hard.

## Slide body (flow)

The body is read by `SlideBlaster.Syntax.Block.readFlow`, which is total and
exact (`printFlow (readFlow t) == t`). Blocks: paragraphs (TeX-aware: open
braces, environments and display math extend across blank lines), `-`/`*`/`+`
and `1.` lists with nesting, `>` quotes, fenced code with an info string
(language, `{1|3-5}` highlight steps, options), `:::` containers with arguments
(`::: columns`, `:::: column 55%`), and pipe tables. Inline text is TeX with
Markdown inline spans (`readTex`).

Inline and block constructs lowered by the alpha:

| Construct | Meaning |
|---|---|
| `\only<s>{..}`, `\uncover`, `\onslide`, `\visible`, trailing `<s>` | Overlay hook over a Beamer spec |
| `\pause` | Pause directive |
| `\sbbox[opts]{title}{body}`, `\newenvironment` boxes | Box container |
| `\figure[opts]{path.tikz}`, ```` ```tikz ````, `![alt](path)` | Figure or image block with a deterministic handle (`<slide>-figure-N`, `<slide>-image-N`) and a resource record carrying the path |
| `\footnote`, `\cite*`, `\bibliography` | Footnote and citation containers |
| ```` ```lang {steps} ```` | Code listing with highlight steps |
| `\newcommand`, `\newenvironment`, `\definecolor` in `preamble` | Defines (D4), expanded into the flow |
| Anything else | Retained exactly; an opaque unsupported node plus a diagnostic (D8) |

Overlay specs follow Beamer: `<2>`, `<2->`, `<-3>`, `<2-4>`, lists separated by
commas. Incremental forms (`+`) are reported and shown always. The audience
scene alone sets the beat count.

## Sections, routes and progress

### Sections

A column-0 `# Title {#id}` line outside fenced code opens a **section**: it holds the
slides after it up to the next `#` line. Slides before the first section (and the
generated title slide) belong to no section. The id follows the slide id rules and is
unique among sections (a repeat is the hard container failure `route.duplicate-section`);
without `{#id}` it is the slug of the title. A `# Title` line before the first slide,
without an id, stays the deck title override described above; with `{#id}` it is a section.
The heading is not part of any slide's span, so slide writers never move or delete it;
`moveSlideAfter` leaves section lines where they are and trades only the slides.

Each section gets a generated **divider slide** (frame id `section-<id>`): the section title
large and centred, and any text between the `#` line and the first `##` as a subtitle. It is a
slide in every respect (page numbers, routes, presenter, the Beamer export) except that it is
not editable and is not among the slides the writers address. Opt out per section with
`# Title {#id .nodivider}`, or for the whole deck with frontmatter `sectionSlides: false`. The
theme lays it out with an optional `sectionSlide` block, like `titleSlide`; the built-in default
centres `title` and `subtitle`:

```json
"sectionSlide": {
  "title": { "x": 1.6, "y": 4.2, "w": 12.8, "h": 1.5, "align": "center" },
  "subtitle": { "x": 1.6, "y": 3.2, "w": 12.8, "h": 0.8, "align": "center" }
}
```

Furniture (logo, page number, footer) applies to the divider as to any non-first slide. The
session view lists sections (`id`, `title`, `frames`, `first`, `last`) and each navigator item
names its section. The footer template `{{section}}` is the current section's title (empty
outside sections), next to `{{title}}`, `{{page}}`, `{{pages}}`.

### Routes

Frontmatter `routes` orders sections for different talks from one deck. The first route is
the default; entries are section ids:

```yaml
routes:
  ai-first: [intro, llm, leash, tovrin]
  fm-first: [intro, tovrin, llm, leash]
```

The block list form (`name:` then `- id` lines) is also read. Slides before the first section
stay first in every route; a section a route does not list is not visited on that route. A deck
without `routes` has one implicit route, the file order.

A choice goes anywhere in a slide body, normally alone on a line, one per route:

```
\route{ai-first}{AI and software development}
\route{fm-first}{Formal methods}
```

It renders as a large numbered button. In the HTML presenter (audience window, console, editor
driving them over the broadcast channel), a click on a button, or the digit key `1..n` (the
n-th choice on the slide), selects the route; the audience window zooms the slide out and the
first slide after the choice on that route in (about 600 ms, none under
`prefers-reduced-motion`). Until a choice is made the default route applies. Next/back, `home`
and `end`, the page number `{{page}}/{{pages}}`, the console's "Slide n / m" and next-slide
preview, and the progress bar all follow the selected route. Choosing again on a revisited choice
slide switches route. The route buttons stay on the slide in the editor and in exports.

`sb check` validates routes: a section id no section has (error, `route.unknown-section`), a
repeated section id in one route (error, `route.duplicate-entry`), a repeated route name (error,
`route.duplicate`), a repeated section id (error, `route.duplicate-section`), a `\route` naming a
route the frontmatter does not define (error, `route.unknown-choice`), and a section a route never
visits (warning, `route.missing-section`).

Beamer/PDF export (`slideblaster-export`, `latexOptionsWithRoutes`) prints each section **once**, in
default-route order (sections the default route omits follow, in file order). Every slide
carries `\hypertarget{sbframe-<id>}{}`; a `\route` button becomes
`\hyperlink{sbroute-<slide>-<route>}{label}`, whose `\hypertarget` sits in the first slide after the
choice on that route. The last slide of each section ends with a small line
`Continue: route: Next title, ...` with one `\hyperlink` per route that continues past that
section; routes that end there are omitted, and routes that continue to the same section each get
their own link.

### Progress bar

A theme furniture item of kind `progress` draws a thin bar showing the position in the talk on
the active route (page over pages): a `rule`-coloured track the width of its region and a fill in
the palette colour named by `fill` (default `accent`). `"per": "section"` shows the position within
the current section instead (nothing outside sections). It is off unless a theme lists it; no
shipped or deck theme does. To enable it, add to the theme's `furniture` array (here a bar along
the bottom edge, on every slide but the first):

```json
{ "kind": "progress", "slides": "not-first", "x": 0, "y": 0, "w": 16, "h": 0.08, "fill": "accent" }
```

and, for a per-section bar in another colour above the first,

```json
{ "kind": "progress", "slides": "not-first", "per": "section", "x": 0, "y": 0.12, "w": 16, "h": 0.05, "fill": "link" }
```

## Sub-presentations

A deck can contain other decks. A block-level line at column 0, outside fenced code and outside
any slide body (where a `##` heading could start; typically right after a `# Section {#id}`
heading), splices another deck's slides in at that point:

```
# Yaaihh {#yaaihh}

\include{../slides-yaaihh-talk}
\include[titleslide,dividers]{extras/appendix.slideBlaster.md}
```

The path is a folder (its single `*.slideBlaster.md`) or a `.slideBlaster.md` file, relative to the
including deck's folder (it may leave it with `..`). Options, comma separated in `[..]`:
`titleslide` keeps the child's generated title slide (default: dropped) and `dividers` keeps the
child's own section divider slides (default: dropped). The line owns the prose after it up to the
next heading, which is not shown. A line inside a slide body is slide text, not an include.

The child's slides become slides of the enclosing parent section (or of no section when the
include precedes the first `#`), in the child's order. Page numbers, `{{page}}`/`{{pages}}`, the
progress bar, presenter navigation and routes (which name *parent* section ids) treat them as
ordinary slides. The child's own `#` sections are **subsections**: the session view lists them in
`subsections` (`id`, `title`, `parent` = the parent section id or null, `deck`, `frames`, `first`,
`last`) and each navigator item names its innermost one in `subsection`; they take no part in
routes, `{{section}}` or per-section progress.

**Namespacing.** A child slide's frame id and a child section's id become `<childkey>/<id>`, where
the childkey is the child's folder name (or file stem for a file include), lower-cased to
`[a-z0-9-]`; nested includes compose (`kid/grand/g`). Ids never collide with the parent's because
`/` is not an id character. Two includes with the same childkey are `include.duplicate`. Figure
and image handles are prefixed per deck as well.

**Per-deck resources.** The *parent's* theme applies to every slide (the child's `theme:` is
ignored). Everything else stays with its deck: the child's `preamble:` (macros, colours) applies to
its own slides, `\figure`/`\input`/image paths resolve relative to the child's folder, and
citations resolve against the child's `bibliography:` first, then its includers' (numeric labels
are numbered per deck). The child's frontmatter `routes:` are not used.

**Read-only.** Included slides cannot be edited from the parent: `new_slide` on one is rejected
(`edit_rejected`, detail starting `include.read_only`) and its command is disabled with reason
`include.read_only`; navigator items carry `origin: {deck, path, readOnly, code}`. The source pane
shows only the parent file, where the include line is the parent's text, and an included slide's
span is that line. The web editor paints included slides without interaction targets and with a
"from <childkey> - open" badge; in the desktop shell "open" switches to the child (the shell's
`open_presentation`), in a browser it is a label. Child decks stay standalone: opened alone they
present with their own title slide as usual.

**Diagnostics** (at the include line; `sb check` reports `include.*` and the parent's route and
section findings): `include.missing` (error: no such folder, file or deck; also absolute paths),
`include.cycle` (error), `include.ambiguous` (error: several decks in the folder),
`include.duplicate` (error), `include.failed` (error: the child cannot be read, with its first
error), `include.option` (warning). Diagnostics of the child's own slides are shown on the include
line prefixed `[childkey]`.

**Loading and watching.** The project loader (`sb serve`, `sb build`, `sb check`) reads the
included decks' folders (a file include contributes its folder, except an ancestor of the project
folder, which contributes the file alone), keyed `_up/<..>` for paths above the project folder,
and `sb serve` watches them, so a change to an included deck or one of its figures refreshes the
parent. A newly added include is picked up when the parent file is saved.

**Desktop sidebar.** Under each presentation the sidebar nests the decks it includes (read from the
`\include` lines of its deck, recursively, smaller and indented); clicking one opens that deck.
They are derived, never stored: a deck appears at top level only if it was added (or opened
directly) as a presentation itself.

PDF/LaTeX export is not wired to the CLI and works from the deck's own presentation, so it does not
splice included slides yet.

## Picture tier and notes

A top-level ```` ```slide ```` fence holds TikZ-superset statements: `\node[..]
(name) at (x,y) {content};` becomes an absolutely placed node (coordinates in
slide units, height 9); other statements are retained opaque. A top-level
```` ```notes ```` fence is the speaker-notes flow, lowered into the notes
scene.

## Scene

A slide lowers to title and body region nodes (theme master regions, generated
placement, fixed size) plus the picture nodes, in one scene; notes form a
second scene. Slide size is 9 units high; `16:9` gives 16 x 9, `4:3` gives 12 x 9.

## Building: offline HTML and PDF

```
sb build --html DECK [-o OUT.html] [--web DIR]
sb build --pdf  DECK [-o OUT.pdf]  [--steps] [--web DIR]
```

Both open the deck's folder as a project (included decks, figures, images, the deck-local theme),
compile every figure through the same broker `sb serve` uses, and project every slide and step to
session/1 plans (`deckExportValue`). The result is one self-contained page: the plans as inert
JSON, the host's offline viewer (`hosts/web/dist/offline/viewer.js` and `.css`: the editor's own
painter, KaTeX with its fonts, Shiki code highlighting) and the deck theme's stylesheet
(`themes/<name>/<css from theme.json>`, deck-local first, else the bundled theme) with every
relative `url()` (fonts, images) inlined as a data URI. Images and figures are already bytes in
the plans. Without `-o` the output is `<deck stem>.html` or `.pdf` next to the deck.

**PDF.** `--pdf` writes that page in print mode to a scratch folder and has headless Chrome print
it (`--headless=new --no-pdf-header-footer --print-to-pdf`, a temporary profile, a virtual-time
budget so math, fonts and highlighting settle). The browser is `$SB_CHROME` (an error if set and
missing), else the first of `google-chrome`, `google-chrome-stable`, `chromium`,
`chromium-browser` on `PATH`; with none, `sb` says so and exits 1. The same print layout is what
Ctrl+P prints from the offline HTML page.

- One page per slide, exactly the slide aspect with no margins (16:9: 254 x 142.875 mm; Chrome
  rounds the height to 142.83 mm), backgrounds printed, no viewer chrome or editor badges.
  Text stays text (fonts embedded) and the fonts are the ones the editor would use on that
  machine: a theme font that is not installed falls back exactly as in the editor, so ship the
  font in the theme (`@font-face` with a relative `url()` in `theme.css`) for a stable look.
- Overlays: by default each slide shows its **final** step (a handout). `--steps` prints one page
  per step (Beamer-like); the slide's link target is its first page.
- Sections and routes follow the Beamer rule above: every section once, default-route order,
  sections the default route omits afterwards, in file order. Page numbers `{{page}}/{{pages}}`
  are those of the plans (the default route). Every slide is a link target `sbframe-<id>`; a
  `\route` button is a real PDF link to the first slide after the choice on that route; the last
  slide of a section carries a small `Continue: route: Next title, ...` line, one link per route
  that continues past the section.
- Included sub-presentations print as ordinary slides of the including section; section divider
  slides are slides.
- Speaker notes are not printed.

`sb serve` offers the same build to the editor (`POST /export/pdf`, `cap-websocket.md`); the
web host's **Export PDF** button writes `<deck>.pdf` beside the deck.

## Writers

Each writer is one exact replacement against the revision the caller saw,
followed by a reparse that must be ready and show the expected slide order:
`newSlideAfter`, `duplicateSlide`, `deleteSlide`, `moveSlideAfter`, `setSlideId`
(`SlideBlaster.Deck.Edit`). Copying or creating a slide after the last one may
add the blank separator line.

## Known gaps

- PDF export: a title that wraps onto a second line overlaps the body (the plan places it in a
  one-line region; the editor shows the same); notes pages and `--notes` are not implemented;
  the PDF needs Chrome or Chromium on the machine.

- Implicit ids renumber by position, so a writer that shifts implicit slides is
  rejected by verification; write ids first.
- Multiple ```` ```slide ```` or ```` ```notes ```` fences on one slide are
  concatenated; diagnostics after the first fence point at the first fence.
- Drag edits of picture nodes (coordinate write-back) are not yet implemented.
- Frontmatter is read-only; metadata edits are plain text edits.
