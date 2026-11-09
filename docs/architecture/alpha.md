---
status: accepted
updated: 2026-11-06
---

# SlideBlaster 0.2.0-alpha: build design

This is the single design the implementer agents build from. It merges
`alpha-design-A.md` and `alpha-design-B.md` (both kept alongside as background and
inventory; where they disagree, this document wins). The product owner has
pre-authorised every decision in section 1, so the "user decision required" gates in
`slideBlaster2/AGENTS.md` that those decisions touch are already passed. Anything
*not* covered here that hits such a gate is recorded in the lane report as a
"default, revisitable" choice and the lane continues; it does not stop.

The product owner will judge this design by **using the alpha**, so the plan is
ordered to put a runnable, thin-but-whole product in their hands first
(milestone W, the walking skeleton), then deepen it.

Short names: **SB2** = this repository (the
base repo; branch `dev`), **ED** = the earlier SlideBlaster editor,
**SE** = the earlier slide-editor prototype, **DS** =
the SlideBlaster design notes. ED and SE are read-only oracles and
sources to port from; they are never modified.

---

## 1. Settled decisions

| # | Decision | Notes |
| --- | --- | --- |
| D1 | **SB2 Haskell core is the base**, native + Wasm, per ADR 0025. Haskell owns all document meaning; the host is a DOM/effect interpreter. | ED's and SE's TS engines are not ported as code; their tests become oracle vectors. |
| D2 | **Format: `*.slideBlaster.md`** (frontmatter, `## Title {#id}`, flow body, optional ```` ```slide ```` picture block, optional ```` ```notes ````). The provisional `.slide` trial format is retired; its span/ids/insertion engine in `slideblaster-deck` is reused with new delimiters. | Section 3. Container declares `slideblaster: 1`. |
| D3 | **Two tiers, one scene model.** Flow body desugars to theme-region-placed `title` + `body` nodes; a ```` ```slide ```` block adds absolutely/relatively placed TikZ-superset nodes to the same scene. | Recorded as an amendment to ADR 0004/0007 by lane A. |
| D4 | **Defines, not constructs.** Primitives are tiny (`\sbbox`, `columns`/`column`, `\figure`, `grid`); `block`, `alertblock`, `\defn`, `theorem` etc. are user-writable `\newcommand`/`\newenvironment` definitions in a theme prelude or the deck `preamble:`. | `\newenvironment` support is added to `Syntax.Expand`. |
| D5 | **TikZ is compile-to-SVG only** (`latex` → `dvisvgm --no-fonts`), as the first extension. Editable/structural TikZ, collab, auth, billing, browser git, browser TeX are later extensions behind the same interface. | Section 4. |
| D6 | **Source-first alpha.** Authoring loop (source pane + live preview), figures, overlays, notes, presenter, HTML/PDF export come first. Canvas: keep SB2's verified move; add resize/delete/z-order and slide add/delete/duplicate/reorder after. Inline on-canvas text editing is deferred. | |
| D7 | **Overlays use Beamer spec grammar** with reserved geometry (ADR 0018). Consecutive sibling `\only` blocks form an **alternation cell** (box = max of members); a lone `\only` behaves like `\uncover`. | |
| D8 | **Unknown syntax is retained exactly**, shown as a labelled opaque region with a diagnostic, never blocks save/commit (adopts `.META/design/input-dialects-and-style.md`, superseding ADR 0015's hard error). | |
| D9 | **Two builds, Desktop first.** *Desktop* (the alpha): a **Tauri app** (thin Rust shell: window, menus, file dialogs, packaging) whose webview runs the TS UI and which starts the native Haskell `sb` binary as a **sidecar**; the Haskell **core runs natively inside `sb serve`** and talks to the UI over a local WebSocket using `session/1`. *Web* (later milestone W-web): the same core compiled to Wasm runs in the page, same `session/1` messages over an in-page call, no Wasm toolchain needed for the alpha. `sb` = `slideblaster-cli` with `check`, `build`, `serve`, `new`, `import`; `sb serve <dir>` (warp + websockets, native only) is also usable headless/in a plain browser tab for dev and CI. Core packages stay Wasm-portable (no native deps outside adapters/apps). | Product owner decision 2026-11-06. |
| D10 | **Host in TypeScript**, bundled with esbuild, checked with `tsc --noEmit`. Code pane: **CodeMirror 6**. Highlighter: **Shiki** with lazily loaded grammars and a hand-written P4 TextMate grammar. Math: **KaTeX**. | Default, revisitable. |
| D11 | **Citations in Haskell** (new `slideblaster-cite`): BibTeX reader, numeric + author-year, `\cite`, `\citeyear`, `\citefootnote`, `[@key]`, generated bibliography slide. | |
| D12 | **PDF** = headless Chromium (`chromium`/`google-chrome` on PATH, or Playwright's) printing the exported HTML one page per beat; absence is a typed capability error (browser print dialog remains). | |
| D13 | **Importers**: `sb import legacy-div` (SE's absolute-`div` format, so an existing legacy-div deck opens) is in the alpha. Beamer `.tex` import is deferred; Beamer *export* (existing writer) is kept best-effort. | |
| D14 | **Version** `0.2.0-alpha.N`. Cabal stays `0.2.0.0`; a `PRERELEASE` file (`alpha.1`) is added and `scripts/release/check-versions.sh` learns it. Releases are local tags only; nothing is pushed. | |
| D15 | ED `services/*`, the 2,257-shape draw.io catalogue UI, animation playback, rotation: untouched/deferred. | |

---

## 2. Architecture

**Desktop build (alpha):**

```
Tauri app (Rust, thin): window, menus, file dialogs, packaging
   +-- webview: TS UI (painter, CM6 pane, KaTeX, Shiki, presenter)
   |        |  WebSocket  session/1  (+ /cap effects)
   +-- sidecar: `sb serve` (native Haskell): the core + FS, git, TeX->SVG, PDF
```

**Web build (later, W-web):** the same TS UI with the core as Wasm in the page;
`session/1` over an in-page call; effects via IndexedDB/FSA or an optional remote
`sb serve`. The diagram below shows the shared layering; in Desktop the
"Haskell core" box lives inside `sb serve`.


```
 project dir: talk.slideBlaster.md, figures/*.tikz, refs.bib, themes/, assets/
                                   |
 +---------------------------------+-------------------------------------------+
 |  Haskell core (shared packages; native + Wasm)                              |
 |  source -> deck -> syntax (mixed dialect + blocks) -> document/diagnostics  |
 |  -> canvas + presentation (flow desugaring, overlays, beats, notes)         |
 |  -> render (measure requests, layout, closed plan)                          |
 |  app reducer (history, leases, commands); export planners/writers;          |
 |  extension broker (requests, tickets, fingerprints, typed absence)          |
 +------------------+-------------------------------------+--------------------+
   session/1 protocol (additive successor of Product/2)   |  same packages,
 +------------------+---------------------------+         |  natively:
 |  Web host (TypeScript)                       |   +-----+--------------------+
 |  Wasm loader; plan painter (HTML + SVG);     |   | sb check / build / import|
 |  DOM measurer; KaTeX; Shiki; CM6 code pane;  |   | sb serve: static host +  |
 |  navigator; presenter windows; export UI     |   |  /cap WebSocket bridge   |
 +------------------+---------------------------+   +-----+--------------------+
                    |  capability + extension envelope (JSON)  |
                    +------------------------------------------+
                         providers: fs, git, tex.compile, pdf.print, ...
```

Rules every lane obeys:

1. The host never parses decks, mints ids, computes revisions, or chooses edits
   (existing `docs/specs/product-v2-protocol.md` rule; enforced by a grep gate in
   `make check`: no imports of deck/syntax logic under `hosts/web/src`).
2. Every mutation is an exact-byte `SourceReplacement` with a revision fence;
   unrelated bytes never change (locality law).
3. Results from the host or providers are accepted only when their echoed
   session/revision/ticket/fingerprint match (`App.Lease` rule).
4. Core packages stay Wasm-portable (no native-only deps outside `adapters/` and `apps/`); the Wasm build itself is verified in W-web, not in the alpha.

### 2.1 Packages

| Package | Status | Alpha responsibility |
| --- | --- | --- |
| `slideblaster-source` | existing | unchanged |
| `slideblaster-syntax` | extend | Markdown blocks (lists, quotes, fenced code with info string, GFM tables, `:::` containers), overlay specs, `\footnote`, `\newenvironment`, `tabular` subset, opaque-retained unknowns |
| `slideblaster-deck` | from worktree, retarget | Markdown container reader + narrow writers (new/duplicate/delete/reorder slide, set id) |
| `slideblaster-document` | extend | diagnostics with spans: overflow, missing asset, unknown cite key, provider error, unsupported |
| `slideblaster-canvas`, `slideblaster-presentation` | extend | flow desugaring; overlay specs → beats; alternation cell; notes scene |
| `slideblaster-render` | extend | flow/picture → plan lowering; theme furniture; `BlockPlaceholder`; measurement requests for content |
| `slideblaster-export` | wire | HTML (offline), PDF plan, Beamer project, zip |
| `slideblaster-app`, `slideblaster-product-runtime` | extend | `session/1` requests: `open_project`, `provider_result`, `export`, `present_*`, slide ops |
| `slideblaster-protocol` | extend | `session/1` codec (Product/2 renamed and grown additively) |
| `slideblaster-tikz` | unchanged | stays the seed of the later editable-TikZ `BlockEditor` |
| **`slideblaster-extension`** | new | manifest type + validation, slot registry, fingerprints, tickets, cache keys, typed absence |
| **`slideblaster-cite`** | new | BibTeX reader, formatters, bibliography generation |
| **`slideblaster-listing`** | new | code-listing model: language, line numbers, highlight sets, per-step highlight spec |
| **`slideblaster-import`** | new, small | `legacy-div` → `slideblaster-md` |
| `slideblaster-adapter-native` | extend | TeX runner, Chromium print, file watch |
| `apps/slideblaster-cli` | extend | `sb check|build|serve|new|import` |
| `apps/slideblaster-web-wasm` | extend | `session/1` reactor exports |
| `hosts/web` | rewrite to TS | painter, panes, presenter, providers client |

Every new package is added to `cabal.project*`, `PROJECT.md` (package map) and
`scripts/release/check-versions.sh`.

---

## 3. Source format (`slideblaster: 1`)

### 3.1 Container grammar (sketch)

```
deck        := frontmatter? preamble-text? slide*
frontmatter := "---\n" YAML "\n---\n"
slide       := "## " title-inline (" {#" id "}")? "\n" slide-body
slide-body  := (flow-block | slide-fence | notes-fence)*      -- until next "## " at column 0 outside fences
slide-fence := "```slide" attrs? "\n" tikz-superset "\n```"
notes-fence := "```notes\n" flow-content "\n```"
id          := [a-z0-9][a-z0-9-]*                              -- minted as first unused slide-N on first edit
```

Laws (all property-tested over the corpus): `print(read x) == x` byte-exact; editing a
slide changes bytes only inside that slide's span; inserting a slide is a single
insertion between slide spans; malformed input yields a read-only document with
diagnostics, never a silent rewrite. Lines `# ...` (level 1) before the first `##`
are a title slide generated from frontmatter (`title`, `subtitle`, `authors`,
`institute`, `date`).

Frontmatter keys: `slideblaster` (format version), `title`, `subtitle`, `authors`,
`institute`, `date`, `theme` (dir name under `themes/` or built-in `default`/`fns`),
`aspect` (`16:9` default, `4:3`), `bibliography`, `citation-style`
(`numeric`|`author-year`), `preamble` (TeX: macros, colours, defines; shared by math,
content expansion and compiled figures), `listing-defaults` (font size, line
numbers). Unknown keys are retained and reported as info diagnostics.

### 3.2 Flow content

The existing three-dialect inline syntax (TeX/Markdown/HTML, per-construct dialect
preserved) plus blocks:

| Construct | Spelling | Notes |
| --- | --- | --- |
| Lists | `- ` / `1. ` / nested; `\begin{itemize}\item<2->` | overlay spec as trailing `<spec>` on Markdown items or Beamer `\item<spec>` |
| Columns | `::: columns` / `:::: column 48%` | primitive |
| Box | `\sbbox[style opts]{title}{body}` | primitive; `block`/`alertblock`/`\defn` are defines (3.4) |
| Math | `$..$`, `$$..$$`, `\[..\]`, `align*`, `cases`, `array` | KaTeX; preamble macros expanded by core; unsupported → diagnostic + optional TeX-compile fallback via `tex` block kind |
| Code | fenced ```` ```p4 {1,3-5|7} ```` (lines `1,3-5` highlighted on step 1, `7` on step 2; `|` separates steps); `\begin{lstlisting}[language=P4,...]`; `\lstinputlisting[language=Haskell]{hs/X.hs}` | `slideblaster-listing`; verbatim, never expanded |
| Tables | GFM pipe tables; `\begin{tabular}` subset (l/c/r/p{}, `\hline`, booktabs `\toprule/\midrule/\bottomrule/\cmidrule`, `\multicolumn`, math cells) | out-of-subset → `tex` block compiled, labelled "compiled" |
| Figures | `\figure[opts]{figures/arch.tikz}`, `\figure[opts]{inline TikZ body}`, `![alt](figures/arch.tikz)`, `![alt](img.svg|png)`, fenced ```` ```tikz ```` | `.tikz`/inline TikZ → `tikz` provider; images → plain resources |
| Overlays | `\pause`, `\only<s>{}`, `\uncover<s>{}`, `\onslide<s>{}`, `\visible<s>{}`, `\item<s>`, `\sbbox<s>`, node `overlay={s}` | spec grammar: `n`, `n-`, `-n`, `n-m`, comma unions |
| Citations | `\cite{k}`, `\cite[p.~3]{k}`, `\citeyear{k}`, `\citefootnote{k}`, `[@k]` | `\citefootnote` puts the formatted reference in the slide footer region |
| Footnotes | `\footnote{..}` | footer region |
| Unknown | anything else | retained, opaque, diagnostic |

### 3.3 Picture tier

The ```` ```slide ```` fence is the DS format's TikZ superset (`DS/format/slideblaster-md.md`,
`DS/format/tikz-subset.md`): `\node[style opts] (id) at (x,y) {content};`, relative
placement (`below=0.5 of id`), `\draw[->] (a) -- (b);`. Coordinates are slide units
(16×9, origin bottom-left). Node content is flow content. A slide may have a flow body
*and* a ```` ```slide ```` block; picture nodes are layered above the body. Anything
outside the supported subset inside a ```` ```slide ```` block is retained and shown
opaque; use `\figure` for real TikZ.

### 3.4 Defines (complete user example)

The default theme prelude ships these as ordinary definitions; a user can copy,
change or add to them in `preamble:` without a SlideBlaster release:

```tex
% themes/default/prelude.tex  (built-in; users override in the deck preamble)
\newenvironment{block}[1]{\sbbox[fill=theme.block.bg, title fill=theme.block.title]{#1}\bgroup}{\egroup}
\newenvironment{alertblock}[1]{\sbbox[fill=theme.alert.bg, title fill=theme.alert.title]{#1}\bgroup}{\egroup}
\newcommand{\defn}[2]{\sbbox[fill=palBlue!10, title fill=palBlue]{Definition: #1}{#2}}
\newcommand{\lemma}[1]{\sbbox[fill=palGreen!10, title fill=palGreen]{Lemma}{#1}}
```

The implementation of `\newenvironment` expansion may realise `\bgroup..\egroup` as
"body = environment contents"; the observable law is: `\begin{block}{T} X \end{block}`
renders exactly as `\sbbox[...]{T}{X}` and round-trips byte-exactly.

Themes are data too: `themes/<name>/theme.json` (palette, fonts, regions for title,
body, footer, safe area; furniture: logo, page number, footer text) + `prelude.tex` +
assets. Shipped: `default` and `fns` (converted from `SE/styles/slide-themes/{default,fns}`).

### 3.5 Complete example deck (the format's normative sample; lives in `fixtures/corpus/unit/all-features.slideBlaster.md`)

````markdown
---
slideblaster: 1
title: "P4Check"
subtitle: "Branching-time model checking for P4"
authors: Tommaso Pacciani
institute: University of Amsterdam
date: 2026-11
theme: fns
aspect: 16:9
bibliography: refs.bib
citation-style: numeric
preamble: |
  \definecolor{palBlue}{HTML}{1F4E79}
  \definecolor{palGreen}{HTML}{2E7D32}
  \newcommand{\defn}[2]{\sbbox[fill=palBlue!10, title fill=palBlue]{Definition: #1}{#2}}
  \newcommand{\Reach}{\mathsf{Reach}}
---

## Why verify data planes? {#why}

- Testing shows the presence of bugs, not their absence \citefootnote{dijkstra1970}
- A P4 program is a state machine over packets <2->
- We check $\mathcal{M} \models \mathsf{AG}\,\neg\mathit{bad}$ <3->

\defn{Safety}{No reachable state satisfies $\mathit{bad}$.}<4->

```notes
Open with the outage story. Step 3 is the pivot to model checking.
```

## The program {#prog}

::: columns
:::: column 55%
```p4 {2|3-4}
control Ingress(inout headers h) {
  table fwd { key = { h.ipv4.dst: lpm; } actions = { route; drop; } }
  apply {
    fwd.apply();
  }
}
```
::::
:::: column 45%
\begin{block}{Observation}
Table contents are \only<1>{fixed}\only<2>{symbolic} during checking.
\end{block}
::::
:::

## Architecture {#arch}

\figure[width=14]{figures/p4checkarch.tikz}

## Results {#results}

| Benchmark | States | Time (s) |
|---|---:|---:|
| basic_tunnel | 1 204 | 0.8 |
| load_balance | 48 911 | 12.3 |

Compared to the state of the art \cite{p4ltl,bf4}.

```slide
\node[sbbox, fill=palGreen!15] (tk) at (12.5,2) {$\Reach$ is decidable here};
\draw[->] (tk) -- (12.5,4);
```

## References {#refs}

\bibliography
````

---

## 4. Extension interface

### 4.1 Slots

Defined as closed records in `slideblaster-extension`. The core owns request/result
types, fences, fingerprints and typed absence; a provider owns only the effect.

| Slot | Request → result | Alpha providers | Later |
| --- | --- | --- | --- |
| `block.render` | `BlockRequest{kind, body, resolvedInputs, preamble, palette, width}` → `Artifact{mime, bytes, size, diagnostics, provenance}` | `sb.tex` (kinds `tikz`, `tex`) via `sb serve` | SwiftLaTeX in browser, Graphviz, Mermaid, plots |
| `block.edit` | `kind` → reader + verified edit intents (reparse law, ADR 0002) | none (interface only) | **editable TikZ** (`slideblaster-tikz`), table editor |
| `content.host` | sync host calls: `math.render`, `code.highlight`, `text.measure` | KaTeX, Shiki, DOM measurer (built in) | MathJax |
| `capability` | existing `slideblaster-ports` records: storage, git, clock, print/pdf, presenter channel, watch | `sb serve` bridge; browser-only: IndexedDB storage, no git/TeX | isomorphic-git, GitHub auth, collab transport, entitlements |
| `export.target` | `ExportRequest` → plan (closed `planExport`) | HTML, PDF, Beamer, zip (built in) | pptx, reveal.js |
| `ui.contribution` | declarative command/panel/status-item slots | git status item only | collab presence, billing pane |

### 4.2 Manifest, transport, cache

Manifest `extension.json` (workspace `.slideblaster/extensions/<id>/` or user
`~/.config/slideblaster/extensions/<id>/`; built-ins are compiled-in manifests of the
same type). Unknown fields are rejected.

```json
{ "id": "sb.tex", "version": "0.2.0",
  "provides": [{ "slot": "block.render", "kinds": ["tikz", "tex"], "output": "image/svg+xml" }],
  "transport": { "kind": "builtin-native" },
  "needs": [{ "tool": "latex" }, { "tool": "dvisvgm" }],
  "permissions": ["exec:tex", "fs:project:read"],
  "limits": { "timeoutMs": 60000, "maxBytes": 8388608 } }
```

Transports: `builtin-native` (Haskell code in `sb serve`), `builtin-host` (TS in the
web host), `stdio-json` (`argv` array, block body on stdin, artifact on stdout; no
shell). The envelope is `{ticket, slot, kind, fingerprint, input, deadline}` →
`{ticket, fingerprint, artifact | diagnostics}`, carried in-process, over the `/cap`
WebSocket, or over stdio.

Fingerprint = SHA-256 of (provider id + version, wrapped input incl. resolved
`\input` closure bytes, preamble, palette, requested size). Artifacts are cached at
`<project>/.slideblaster/cache/<provider>/<fingerprint>` (add to `.gitignore` via
`sb new`). Same fingerprint → no request. Missing provider/tool → typed absence: a
labelled placeholder plus a diagnostic; the deck still opens, saves and exports.

User-writable example, adds Graphviz with no SlideBlaster release (this is a lane-B
acceptance test):

```json
{ "id": "user.graphviz", "version": "1.0.0",
  "provides": [{ "slot": "block.render", "kinds": ["dot"], "output": "image/svg+xml" }],
  "transport": { "kind": "stdio-json", "argv": ["dot", "-Tsvg"], "stdin": "body", "stdout": "artifact" },
  "permissions": ["exec:dot"], "limits": { "timeoutMs": 10000, "maxBytes": 4194304 } }
```

### 4.3 Worked example: TikZ → SVG

1. Reader yields `Block{kind=tikz, source=File "figures/arch.tikz" | Inline span, opts}`.
2. Broker builds the request: a `\documentclass[tikz,border=1pt]{standalone}` wrapper
   (port `buildStandaloneDocument` from `ED/packages/adapters-shared/src/compile/tikzDocument.ts`,
   including `\usetikzlibrary` inference), deck `preamble`, theme palette as
   `\definecolor`, the body with `\input` closure resolved; a `%%sb-line N` marker per
   source line for error mapping.
3. Plan contains `BlockPlaceholder{ticket, fingerprint, box}`; on cache miss the
   reducer emits a `block.render` effect.
4. `sb.tex` runs in a temp dir outside the project: `latex -interaction=nonstopmode
   -halt-on-error -no-shell-escape`, then `dvisvgm --no-fonts --exact-bbox`; sanitises
   the SVG (no script, no external refs); enforces timeout/size.
5. Success → artifact cached, plan repainted, SVG scaled into the node box.
   Failure → diagnostic at the block's source span with the first `! ...` line and
   mapped line; the last good artifact stays painted with a "stale" badge.
6. Export: HTML embeds the SVG; Beamer export emits the original TikZ verbatim; PDF
   prints the HTML.
7. Editing the `.tikz` file (watched by `sb serve`), the preamble or the theme
   changes the fingerprint and recompiles.

### 4.4 How editable TikZ plugs in later

`slideblaster-tikz` registers a `block.edit` provider for `kind=tikz`. Per figure:
if `block.edit.read` accepts the bytes, the figure is painted from the native plan and
gets handles; otherwise it stays compiled with a labelled reason. The source bytes are
the same either way; `\figure[compiled]` forces the compiled view. The compile
provider remains as the geometric oracle for the native renderer. No format, export or
core change is needed. Collab (`session.sync` over `SourceReplacement`), auth and
billing (`capability` flags feeding `App.Capability`) follow the same pattern.

---

## 5. Alpha features and acceptance

| # | Feature | Acceptance (executable) |
| --- | --- | --- |
| F1 | Open/save project folder, exact source, undo/redo | edit → save → reload byte-identical; 3-step undo to exact original; stale edit rejected |
| F2 | Container + slide ops (new/duplicate/delete/reorder) | `print(read x)==x` over corpus; reorder = minimal span moves; `sb check` exit 0 on corpus, non-zero with `file:line:col` on a broken deck |
| F3 | Basic slides: title slide, lists, columns, boxes, defines, images, quote | `unit/*` render with zero diagnostics; seeded 14-bullet slide raises an overflow diagnostic naming the line |
| F4 | Math | all math in corpus renders via KaTeX; unsupported → diagnostic |
| F5 | Code listings, P4/Haskell/C/Python/bash, line numbers, stepped highlights | LDWG `lstlisting` blocks converted render; highlighted lines per beat match the spec |
| F6 | Tables | pipe + `tabular` subset native; `\multirow` table via `tex` block with "compiled" badge |
| F7 | Citations | DevDays `\cite`s resolve from `refs.bib`; unknown key diagnostic at the cite; numbering unaffected by notes |
| F8 | TikZ → SVG | `p4checkarch.tikz` used on 4 slides compiles once (cache counter); warm refresh < 5 s; TeX error mapped; provider absent → placeholder; Graphviz manifest test passes |
| F9 | Overlays + alternation cell | beats per slide equal Beamer page counts for corpus frames; stationary nodes don't move across steps |
| F10 | Notes + presenter (audience window + console: notes, next slide, step, timer) | 100 scripted commands keep both windows on one cursor; notes cannot add beats |
| F11 | Themes `default`, `fns` | switching changes furniture/fonts, not authored coordinates |
| F12 | Export: offline HTML, PDF (page per beat; `--handout` page per slide), Beamer project, zip | HTML opens from `file://` offline; PDF pages == beats; re-export byte-identical |
| F13 | Code pane (CM6) with diagnostics; click preview ↔ source | click node puts caret on its construct; diagnostic on line N shows in gutter + status |
| F14 | Navigator rail; canvas move (existing), resize, delete, z-order | locality law property; undo exact |
| F15 | CLI `sb check|build|serve|new|import` | each runs headless on the corpus; documented exit codes |
| F16 | `sb import legacy-div` | PLp4check deck imports, re-reads cleanly, every slide renders (raw SVG kept as an `html` payload) |
| F17 | Local git status + commit via `sb serve` | commit has exact working-copy bytes; refused while hard diagnostics exist |

Non-goals: Beamer-compatible reflow layout, a TeX engine, animation playback,
collaboration, inline on-canvas text editing, browser-only TeX.

---

## 6. Port map

| From | To | What |
| --- | --- | --- |
| worktree `slideblaster-deck/Deck.hs` | `slideblaster-deck` | span container engine; new delimiters |
| ED `packages/editor/src/markdown/*` + tests | oracle vectors | container round-trip |
| ED `packages/editor/src/content/{tabular,overlay,columns}.ts` + tests | oracle vectors → `slideblaster-syntax` | table + overlay grammar |
| ED `packages/adapters-shared/src/compile/tikzDocument.ts`, `ED/tools/tikz-compile.sh` | `slideblaster-extension` request builder + `adapter-native` TeX runner | standalone wrapper, library inference, pipeline |
| ED `packages/app/src/{math,katexInlineCss}.ts` | `hosts/web/src/content/math.ts` | KaTeX |
| ED `packages/app/src/domMeasurer.ts` | `hosts/web/src/measure.ts` | measurement port |
| ED `packages/app/src/{presenter}.ts` (+test) | `hosts/web/src/presenter/` | two windows, BroadcastChannel, timer; driven by `Presentation.Presenter` |
| ED `packages/app/src/{deck,deckNav,chrome}.ts` | `hosts/web/src/ui/` | continuous deck, rail, top bar |
| ED `packages/app/src/{export,workspaceZip}.ts` | `hosts/web/src/export/` | download/zip effects behind Haskell plans |
| ED `packages/app/src/{citeCompiler,citeRenderer}.ts`, SE `src/rendering/citeRenderer.ts` | oracle vectors → `slideblaster-cite` | formatting |
| SE `styles/slide-themes/{default,fns}` | `themes/{default,fns}` | theme.json + CSS + logos + prelude |
| SE `server/htmlToPdf.ts`, `src/rendering/exportPdf.ts` | `adapter-native` Chromium print | page-per-beat PDF |
| SE `src/rendering/fragments.ts` | host CSS | step transitions |
| SE `src/components/editor/HtmlFolding.ts` | CM6 folding of raw HTML/SVG | idea only |
| worktree `hosts/web/src/ui/{viewport,pointer-event-transport,product-v2-renderer}.js`, `theme-editor.js`, `shape-palette.js` | `hosts/web/src/ui/*.ts` | convert to TS |
| a legacy-div presentation deck | `fixtures/corpus/se-p4check/` | import fixture |
| the P4 Developer Days Beamer talk (`presentation.tex`, `figures/`, `references.bib`, `config.tex`) | `fixtures/corpus/p4devdays/` | acceptance deck, re-authored in the new format; `.tex` as beat-count oracle |
| a Beamer lecture deck (`main.tex`) | `fixtures/corpus/ldwg/` | ~12-frame excerpt: tikz, `\only`, listings, tabular |

Dropped: ED/SE TS engines, SE Express/SQLite/React app, `.slide` format (a temporary
reader may stay one release for old fixtures), Tauri for now.

---

## 7. Milestones and lanes

Base: `dev` after the worktree session (Product/2, deck package, product runtime,
viewport) has been reviewed and merged. Each lane works in its **own git worktree on its
own branch off `dev`**, owns the directories listed, commits small logical commits
(trailer `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`), never pushes, and
merges to `dev` only through the integrator (lane I). Shared files (`cabal.project*`,
`PROJECT.md`, `Makefile`, `check-versions.sh`, protocol schema) are edited only by the
lane that owns them below; others request changes in their report.

### Milestone W — walking skeleton (target: product owner can try it)

Thin but whole: `sb serve talk/` opens a folder; a deck with title slide, lists,
columns, math, a code fence (highlighted, no steps yet), a `\figure{x.tikz}` compiled to
SVG, `\pause`/`<2->` overlays, notes, and the `fns` theme renders in a continuous preview
next to a CM6 source pane; edits re-render; save writes exact bytes; a presenter
window and console work; `sb build --html` writes offline HTML. Rough edges allowed;
laws are not.

| Lane | Owns | W scope | W exit test |
| --- | --- | --- | --- |
| **A — core language** | `packages/slideblaster-{deck,syntax,document,canvas,presentation,listing,cite}`, `fixtures/corpus/`, `docs/specs/slideblaster-md-alpha.md`, ADR amendment for D2/D3/D7/D8 | container reader/writers; Markdown blocks (lists, fences w/ info string, `:::`), overlay specs + `\pause`, `\newenvironment`, `\sbbox`, flow desugaring to title/body nodes; `\figure` block node; notes; corpus `unit/` decks incl. 3.5 sample; ED vectors exported to `fixtures/oracle/` | round-trip + locality properties green on corpus; `cabal test` for touched packages green native |
| **B — extension + native** | `packages/slideblaster-extension`, `adapters/slideblaster-adapter-native`, `apps/slideblaster-cli`, `cabal.project.native`, `.slideblaster` cache layout | broker, manifest, fingerprints, cache, typed absence; `sb.tex` TikZ provider; `sb serve` (warp + websockets, static files + `/cap` storage/watch/tex); `sb check`, `sb new` | `sb serve fixtures/corpus/unit` serves the host; `/cap` compile of `p4checkarch.tikz` returns SVG; second call is a cache hit; missing `dvisvgm` (PATH stripped) → typed absence; Graphviz manifest test |
| **C — UI + desktop shell** | `hosts/web/**` (TS + esbuild), host tests, theme files `themes/`, new `apps/desktop/` (Tauri) | migrate host to TS; CM6 pane; plan painter for HTML content + SVG; KaTeX; Shiki + P4 grammar; DOM measurer; `/cap` client; continuous preview + rail; presenter windows (ED port); `fns`/`default` theme conversion; **Tauri desktop app** in `apps/desktop/` ported from `ED/packages/desktop-shell/src-tauri` (thin Rust: window, menus, open-folder dialog, presenter second window, starts `sb serve` as sidecar on a free port and points the webview at it) | host tests green; Chrome smoke at 1440/820/390 shows the sample deck (using a stub plan fixture until lane I lands); presenter cursor-sync script passes |
| **I — integrator** | `packages/slideblaster-{render,app,product-runtime,protocol,export}`, `apps/slideblaster-web-wasm`, `cabal.project*` (shared), `PROJECT.md`, `Makefile`, `README.md` quickstart | `session/1` protocol served natively by `sb serve` over WebSocket (the core runs in the `sb` process; no Wasm in the alpha); flow/picture → plan lowering with measurement round trip; block placeholders + provider results; HTML export wired to `sb build --html`; merges A, B, C to `alpha` as they land, resolves conflicts, keeps `make check` green | **W demo script** `scripts/alpha/demo-w.sh`: builds everything (native `sb`, host bundle, Tauri app), runs `sb serve fixtures/corpus/unit`, Playwright/Chrome opens the sample deck, asserts every slide paints, figure SVG present, edit → repaint → save byte-exact, presenter opens; `sb build --html` output opens offline. Tag `v0.2.0-alpha.0` locally. |

Lanes A, B, C start in parallel immediately. Lane I starts with the protocol and
lowering against stub inputs and integrates as lanes land.

### Milestone M — complete alpha (after W is in the product owner's hands)

| Lane | Scope | Exit test |
| --- | --- | --- |
| A | GFM + `tabular` subset tables; `slideblaster-listing` stepped highlights + `lstlisting`/`\lstinputlisting`; `slideblaster-cite` + bibliography slide + `\citefootnote`; alternation cell; full overlay forms; `\only` reflow diagnostic; overflow diagnostics; `slideblaster-import legacy-div`; re-author `p4devdays` deck in the format | F5, F6, F7, F9, F16 tests; p4devdays beat counts match its Beamer PDF |
| B | `tex` block kind (math/table fallback); Chromium PDF capability; `sb build --pdf|--tex|--zip`; local git status/commit + diagnostics gate; `sb import` CLI | F8, F12 (PDF), F15, F17 |
| C | stepped code highlight paint; navigator ops (new/dup/delete/reorder), resize/delete/z-order handles; diagnostics gutter; click-to-source both ways; export UI; landing page | F13, F14; Chrome smoke |
| I | wire all of the above; Beamer export; release mechanics (D14: `VERSION` 0.2.0, `PRERELEASE` alpha.1, script change, `CHANGELOG.md`, all Cabal files 0.2.0.0) | full corpus `make alpha-check`; p4devdays presents end to end via `scripts/alpha/demo-m.sh`; tag `v0.2.0-alpha.1` locally |

### Milestone W-web (after the alpha)

Install the GHC Wasm toolchain; build the core reactor (`apps/slideblaster-web-wasm`)
serving `session/1` in-page; host chooses transport (WebSocket to `sb serve` vs in-page
Wasm) behind one interface; IndexedDB/FSA storage; providers absent → placeholders or
a remote `sb serve`. Exit: the same demo script passes in a plain browser with no `sb`.

### Lane process

- Follow `slideBlaster2/AGENTS.md` and `STYLE.md` (totality lint, export lists,
  Haddock module contracts, no partial functions). Use one session record per lane per
  milestone under `.META/sessions/` if the repo tooling expects it; keep it light.
- Write tests first for each law/criterion above; no weakening tests to go green;
  unexpected failures are reported with output.
- Report at the end of each milestone: what landed (commits), test counts, exit-test
  output, default-revisitable decisions taken, known gaps.

---

## 8. Release

`0.2.0-alpha.0` = W (local tag). `0.2.0-alpha.1` = M. `check-versions.sh` accepts an
optional `PRERELEASE` file matching `^(alpha|beta|rc)\.[0-9]+$`; tag name is
`v$(VERSION)-$(PRERELEASE)`. No pushes; the product owner promotes.
Distribution: `cabal install exe:sb` (Linux) with web assets embedded or installed next
to the binary; README quickstart: `sb new talk && sb serve talk`.

---

## 9. Risks

| Risk | Mitigation |
| --- | --- |
| Composition (reader → plan → paint) is most of the work | W slice forces the whole path early; lane I owns it |
| Measurement latency core ↔ DOM (over local WebSocket) | cache by (content hash, width, fonts); measure flow bodies once per edit; fallback: CSS-sized body reports height |
| warp/websockets build trouble | Node bridge fallback (D9) |
| TeX package variance (`pifont`, `zi4`, `svg`) | deck `preamble` precedence; error surfaced with TeX line; tectonic as alternative provider |
| KaTeX gaps | `tex` block fallback, labelled |
| Sidecar lifecycle in Tauri (start, port handoff, crash) | Tauri owns the process; port passed via env/IPC; UI shows reconnecting state; `sb serve` usable standalone for debugging |
| Lanes colliding on shared files | ownership table above; integrator-only for shared files |
| Overlay semantics vs Beamer `\only` reflow | alternation cell + diagnostic |
