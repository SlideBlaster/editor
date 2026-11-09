---
status: proposed
updated: 2026-11-06
supersedes: product-v2-protocol.md
---

# `slideblaster.session/1` protocol

`session/1` is the additive successor of Product/2 (alpha design section 2). Product/2
is renamed, not duplicated: its commands, fences and navigator survive with the same
semantics; the response envelope grows from `{actions, workspace}` to
`{effects, view}`, and the command set grows to carry projects, measurement,
provider (extension) results and presenter control. Haskell is the authority
(`SlideBlaster.Protocol.Session` codec, `SlideBlaster.Product.Runtime.Session` state
machine, `SlideBlaster.Product.Runtime.Driver` effect-interpreting server driver); the TypeScript host mirrors it in
`hosts/web/src/protocol/`. The host still never parses decks, mints ids, computes
revisions or chooses edits.

Everything in `product-v2-protocol.md` not restated here (exact-key objects, bounded
lowercase base16 for authored bytes, source-redacted errors, `surface_not_active`,
revision fences, zoom/pan stay host-local) still holds.

## 1. Envelope

Request: `{"protocol":"slideblaster.session/1","command":<name>, ...fields}`; exact
keys, unknown fields reject.

Success: `{"protocol":"slideblaster.session/1","ok":true,"kind":<string>,
"effects":[Effect...],"view":View}`. Error: `{"protocol":...,"ok":false,
"kind":"error","error":{"code":<string>,"message":<string>}}`. Errors carry no
authored bytes. Failure never mutates state (atomic).

Geometry: all plan geometry is a finite JSON number (rounded to 1/1000 slide unit) in
the **session coordinate space**: origin top-left, x right, y down, unit = one slide
pixel of the theme's design size (`size`, default 1280x720 for 16:9, 960x720 for
4:3). Pointer facts use the same space. Product/2's exact-rational
`slide_16x9_y_up` strings survive only inside the picture tier's source-edit lift,
which is internal to Haskell.

Authored and artifact bytes cross session/1 as lowercase base16 in fields named `...Base16`; the `block.render` effect `request` alone follows `/cap` (base64), so the host relays it verbatim.

## 2. Commands

| Command | Fields | Meaning |
| --- | --- | --- |
| `open_project` | `entry` (project-relative deck path), `files` `[{path, bytesBase16}]` | Open a project. `files` must include the deck; it should include every project file the host holds (`*.tikz`, `refs.bib`, `themes/**`, images). Replaces any open project. Result kind `project_opened`. |
| `open_source` | `sourceBase16` | Product/2 compatibility: one deck, no other files (entry `deck.slideBlaster.md`). |
| `project_file` | `path`, `bytesBase16` or `null` | A non-deck project file was created/changed (bytes) or removed (null); the host forwards watch events. Invalidates dependent artifacts. Result kind `project_file_updated`. |
| `apply_source_replace` | `revision`, `start`, `end`, `expectedBase16`, `replacementBase16` | Exact-byte `SourceReplacement` with a revision fence (CM6 pane edits). Re-analyses and returns the new view. Stale revision or `expected` mismatch rejects. |
| `replace_source` | `revision`, `sourceBase16` | Product/2 whole-source replace (same fences). |
| `command` | `name` plus `revision` where noted | Slide and view operations; enablement is in `view.commands`. |
| `pointer_event` | closed raw pointer fact (Product/2 shape) | Picture-tier move/preview/commit; unchanged semantics. |
| `activate_node` | `surface`, `nodeId` | Unchanged. |
| `select_slide` | `frame` | Stable-identity selection; unchanged. |
| `acknowledge_paint` | `fence` | Unchanged: grant interaction authority for one painted plan. |
| `paint_completion` | `fence`, `outcome` (`"painted"` or `{"failed":code}`) | Host reports a plan was (not) painted. `painted` subsumes `acknowledge_paint` for that fence. |
| `measurement_result` | `ticket`, `results` `[{key, width, height}]` | Answer to a `measure` effect. Stale ticket rejects (`stale_ticket`); duplicate/missing/unexpected keys reject. |
| `provider_result` | `ticket`, `fingerprint`, and `artifact` or `diagnostics` (2.1) | Answer to `block.render`. Accepted only if ticket and fingerprint match an outstanding request for the current revision; otherwise returns kind `provider_result_ignored` (hosts may race; not an error). |
| `storage_result` | `path`, `revision`, `ok` | Answer to a `storage` write effect; `view.saved` advances only on `ok`. |
| `present_open` | `startFrame` optional | Begin presenting; result carries a `present` effect and `view.presenter`. |
| `present_step` | `direction` (`"next"`/`"previous"`) | Advance or retreat one beat (overlay step, then slide). |
| `present_goto` | `frame`, `step` optional | Jump. |
| `present_route` | `route` | While presenting, select a route (specs/slideblaster-md-alpha.md, Routes): the core records it, and moves the cursor to the first slide after the current one on that route. Fails with `not_presenting` or `unknown_route`. `present_open` resets the selection to the default route. |
| `present_close` | none | End presenting. |
| `workspace_snapshot` | none | Return the current view without mutation. |

`command` names: `previous_slide`, `next_slide`, `new_slide`, `undo`, `redo`
(Product/2's set; `new_slide`/`undo`/`redo` keep their `revision` fence); `save`
(emits a `storage` effect for the current bytes); milestone M adds
`duplicate_slide`, `delete_slide`, `reorder_slide`, `set_slide_id`.

### 2.1 `artifact` and `diagnostics` in `provider_result`

```json
{"command":"provider_result","ticket":7,"fingerprint":"<hex sha-256>",
 "artifact":{"mime":"image/svg+xml","bytesBase16":"...","width":212.5,"height":96.0,
             "provenance":"sb.tex 0.2.0"}}
```
or
```json
{"command":"provider_result","ticket":7,"fingerprint":"<hex>",
 "diagnostics":[{"severity":"error","code":"provider_error",
                 "message":"! Undefined control sequence.","line":4,"absent":false}]}
```
`absent:true` is typed absence (missing provider or tool): the core paints a labelled
placeholder plus a `provider_absent` diagnostic; the deck stays editable and saves.
`width`/`height` are the artifact's intrinsic size; the core uses their ratio to fit the
artifact into the figure box.

Theme data is read by the core from `themes/<name>/theme.json` (lane C's format: regions and furniture in 16x9 y-up units, converted to the plan space by the core) passed in `open_project.files`, falling back to the built-in minimal theme. Fingerprint: lower-case hex SHA-256 computed **by the core** over
`kind NUL bodyBytes NUL preambleBytes NUL paletteJSON NUL width*1000 NUL` followed by
`path NUL bytes NUL` for each referenced project file in path order. The broker
(`sb serve`) extends it with provider id/version and the `\input` closure for its
on-disk cache key but echoes the core's `fingerprint` unchanged.

## 3. Effects (response `effects`, interpreted mechanically by the host)

| `kind` | Fields | Host action |
| --- | --- | --- |
| `measure` | `ticket`, `items` `[{key, content, width}]` | Lay out `content` (same closed tree as the plan) at `width` slide units with the theme fonts and answer with one `measurement_result`. Cache by (content hash, width, fonts). |
| `block.render` | `ticket` (number), `fingerprint`, `request`: exactly the `/cap` `block.render` request minus `id` (`slot`, `kind`, `fingerprint`, `deadline`, `input:{body,preamble,palette:[{name,hex}],width,inputs:[{path,contentBase64}],lineMap}`) | Send `request` with `ticket` as `"t-<n>"` string over `/cap`, translate the response into `provider_result` (ticket back to number; `artifact.contentBase64` re-encoded as `bytesBase16` by the host, or `data` utf8 for SVG). A host with no provider answers `absent:true` immediately. |
| `storage` | `op:"write"`, `path`, `bytesBase16`, `revision` | Persist the exact bytes (save); acknowledge with `storage_result`. |
| `present` | `op` (`"open"`/`"close"`/`"goto"`), `frame`, `step`, `window` (`"presenter"`/`"audience"`) | Open or drive presenter/audience windows; plans are in `view.presenter`. |
| `print` | `frames` | Reserved (milestone M). |
| `focus_node`, `slide_selected`, `slide_created` | as Product/2 | unchanged |

Effects are idempotent hints: the host may drop effects for superseded revisions; the
core drops results whose fences no longer match.

## 4. View

```json
{"revision":12,"session":3,"saved":12,"ready":true,
 "frontmatter":{"title":"P4Check","theme":"fns","aspect":"16:9",
                "size":{"width":1280,"height":720}},
 "navigator":{"activeIndex":0,"activeFrame":"why","slideCount":9,
   "items":[{"frame":"why","title":"Why verify data planes?",
             "span":{"start":412,"end":950},"steps":3,
             "audience":Plan|null,"notes":Plan|null}]},
 "active":{"fence":Fence,"plan":Plan,"step":1} | null,
 "diagnostics":[{"severity":"error|warning|info","code":"...","message":"...",
                 "span":{"start":0,"end":3}|null,"frame":"why"|null}],
 "commands":{"previous_slide":Enable,"next_slide":Enable,"new_slide":Enable,
             "undo":Enable,"redo":Enable,"save":Enable},
 "presenter":null | {"frame":"why","step":2,"steps":3,"audience":Plan,
                      "notes":Plan|null,"next":Plan|null,
                      "cursor":7,"total":31,"slide":{"number":3,"count":9},
                      "route":{"id":"fm-first"|null,"default":"ai-first"|null,"frames":["title-slide","why",...]},
                      "choices":[{"route":"ai-first","label":"AI and software development"}]},
 "sections":[{"id":"intro","title":"Intro","frames":["section-intro","why"],"first":"section-intro","last":"why"}],
 "routes":[{"id":"ai-first","default":true,"sections":["intro","llm"],"frames":["title-slide","section-intro","why",...]}]}
```
`sections` and `routes` are empty lists for decks without them; a navigator item adds
`"section":"<id>"|null`. `presenter.route.frames` is the active route's slide order (the default
route until a choice is made; file order when the deck defines no routes). Navigation
(`present_step`), `next` (the console's next-slide preview), `slide` (page of pages), `cursor`/`total`
(beats) and the `{{page}}`/`{{pages}}`/`{{section}}` templates and `progress` furniture all follow
it. `choices` lists the `\route` buttons of the current slide in reading order (those naming a
defined route); hosts map digit keys `1..n` to them and send `present_route`.
`Enable` is `{"enabled":true}` or `{"enabled":false,"reason":"<closed code>"}`.
`items[].steps` is the beat count of the slide (at least 1). Navigator item plans show
finished slides (all steps visible) so the rail and the continuous preview paint
complete slides; `active.plan` is for `active.step`. The source bytes are not echoed
after `apply_source_replace` (the host mirrors the pane); `open_*`/`replace_source`/
`undo`/`redo` add `source:{sourceBase16}` to the view. `span` offsets are UTF-8 byte
offsets into the exact deck bytes (the CM6 pane converts to UTF-16 positions).

## 5. Plan

A plan is closed and self-contained for one `(frame, surface, step)`:

```json
{"protocol":"slideblaster.session/1","frame":"why","surface":"audience","step":1,
 "steps":3,"revision":12,"ticket":41,
 "coordinateSpace":"slide_y_down","size":{"width":1280,"height":720},
 "background":{"fill":"#ffffff"},"items":[ Item ]}
```
`session`+`revision`+`ticket`+`frame`+`surface` is the paint fence.

Items paint in array order (furniture, then regions, then picture nodes):

| `kind` | Fields |
| --- | --- |
| `rect` | `id`, `box` `{x,y,width,height}`, `fill`, `stroke` `{color,width}` or null, `radius`, `opacity`, `hit` (null or `{nodeId}`) |
| `line` | `id`, `from` `{x,y}`, `to` `{x,y}`, `stroke` `{color,width,dash}`, `arrow` (`"none"`/`"end"`/`"both"`), `hit` |
| `text` | `id`, `box`, `style` `{font,size,weight,italic,color,align,lineHeight}`, `content` (inline Content list), `visibility` (`"visible"`/`"reserved"`) |
| `flow` | `id`, `box`, `style`, `content` (block Content list the host lays out as HTML inside `box`), `contentHash`; overflow is visible; the host reports height through `measure` |
| `figure` | `id`, `box`, `fingerprint`, `artifact` `{mime,bytesBase16}` (SVG or PNG), `fit:"contain"`, `stale` bool |
| `image` | `id`, `box`, `resource` `{mime,bytesBase16}`, `alt`, `fit` |
| `placeholder` (item) | `id`, `box`, `label`, `state` (`"pending"`/`"absent"`/`"error"`/`"stale"`), `fingerprint`, `message` optional. Painted as a labelled dashed box. This is `BlockPlaceholder{ticket,fingerprint,box}`; the artifact substitutes it with a `figure` in the next plan. |

Visibility at the plan's `step` is already resolved: invisible items are omitted;
reserved geometry (ADR 0018) is `visibility:"reserved"` (hidden, occupying layout), and
inside a `flow` it is `{"t":"reserved","children":[...]}`.

**Content** (closed tree used by `text`, `flow`, `measure`):

```
{"t":"text","text":"..","bold":b,"italic":b,"mono":b,"color":c|null}
{"t":"p"|"h1".."h6"|"quote"|"ul"|"ol"|"li"|"strong"|"em"|"code"|"cite"|"footnote",
 "children":[Content]}
{"t":"math","display":bool,"tex":"..","label":".."}      -- host runs KaTeX; preamble macros already expanded
{"t":"codeblock","language":"p4","lines":["..",".."],"highlight":[1,3,4]|null}
{"t":"link","href":"..","children":[Content]}
{"t":"table","head":[[Cell]],"body":[[Cell]]}   Cell={"align":"l|c|r","colspan":n,"rowspan":n,"children":[Content]}
{"t":"box","title":[Content]|null,"fill":c,"titleFill":c,"children":[Content]}   -- \sbbox
{"t":"columns","columns":[{"width":"48%","children":[Content]}]}
{"t":"figure","fingerprint":"..","width":w,"height":h}   -- inline figure; resolved from the plan's figure artifacts
{"t":"image","src":"..","alt":".."}  {"t":"br"}  {"t":"reserved","children":[Content]}
{"t":"u"|"s"|"mark","children":[Content]}                  -- underline, strike, highlight
{"t":"colour","color":"#rrggbb","children":[Content]}
{"t":"div","class":"..","children":[Content]}              -- generic container (unknown \begin{env} bodies)
{"t":"placeholder","state":"pending|absent|error|stale","fingerprint":"..","label":".."}   -- inline block not yet rendered
{"t":"unsupported","label":".."}                           -- retained source the core cannot render; labelled, never dropped
```
An inline `{"t":"figure","fingerprint":fp,...}` is resolved against the plan's top-level
`"artifacts":{fp:{"mime","bytesBase16"}}` map (only ready figures of that frame appear
there); a figure whose fingerprint has no artifact is never emitted (the core emits an
inline `placeholder` instead).
Colours are `#rrggbb` (theme palette resolved by the core). An unknown `t` is a host
protocol error, never silently skipped.

## 6. Lowering contract (core behaviour the host relies on)

1. Flow desugaring (lane A) yields per-slide `title` and `body` nodes plus optional
   picture nodes. Lowering places them into theme regions (`theme.json`
   `regions.title|body|footer|titleSlide`, safe area), emits furniture (title bar, logo,
   page number `{{page}}/{{pages}}`, footer text) first, then the title as `text`, the
   body as `flow`, then picture nodes in source order.
2. `\figure` blocks become `block.render` requests and `{"t":"figure"}` content; the
   plan carries a `placeholder` until the artifact arrives, then the figure; stale
   artifacts stay painted with `stale:true` after a failed rebuild.
3. The title slide (frontmatter) is frame `title`.
4. Measurement is advisory in W: the plan never waits for a measurement; results feed
   `overflow` diagnostics and stacking.

## 7. Native serving (alpha, Desktop build) and Wasm (later)

The alpha core runs natively inside `sb serve` (design D9). The UI (Tauri webview or any
browser tab) is a thin client of two WebSocket routes on the same port:

* `/cap` (lane B, `docs/specs/cap-websocket.md`): project storage, watch, providers; used
  by the UI only for things the core does not drive (project listing, dialogs).
* `/session`: **this protocol**. One JSON object per text frame, request in, one response
  out. The server also pushes unsolicited frames `{"protocol":"slideblaster.session/1",
  "ok":true,"kind":"view_updated","effects":[...],"view":View}` when something changed
  without a request (a figure finished compiling, a watched file changed on disk).

Because the core is in-process with storage and providers, the server interprets the
effects it can: `storage` (compare-and-replace write; `view.saved` advances on success),
`block.render` (calls the broker, then feeds the outcome back as `provider_result` and
pushes `view_updated`), and file-watch events (fed back as `project_file`). Those effects
are **not** forwarded; only `measure`, `present`, `focus_node`, `slide_selected`,
`slide_created` and `print` reach the UI in `effects`. In native mode `open_project` takes
only `entry` (`files` optional; the server fills it from the project directory), and
`provider_result`, `storage_result` and `project_file` are internal (the server rejects
them from a UI with `unknown_command`).

Library entry point for lane B: `SlideBlaster.Product.Runtime.Driver`
(`newSessionDriver :: Capabilities -> (ByteString -> IO ()) -> IO SessionDriver`,
`handleSessionFrame :: SessionDriver -> ByteString -> IO ByteString`). `Capabilities`
supplies `listProject`, `readFile`, `writeFile` (with expected bytes), and `renderBlock`
(a plain record: kind, body, preamble, palette, width, inputs; result: artifact or
diagnostics), so the driver does not depend on `slideblaster-extension`; `sb serve` adapts
its broker to it. The second argument is the push callback.

Wasm (milestone W-web) reuses the same pure runtime behind `sb_session_dispatch` and
interprets all effects in the page; nothing in the wire changes. It is not built or
verified in the alpha.

* `slideblaster.product/2` is renamed to `slideblaster.session/1`; the old string is
  rejected with `unsupported_protocol`. Product/1 and Engine/1 are untouched.
* `sb build --html` links the same packages and calls
  `SlideBlaster.Export.exportDeckHtml` (lane I library entry point).
* The whole-deck value (`deckExportValue`) also carries what a printed deck needs: top-level
  `theme` (name) and `order` (frame ids: lead, each section once in default-route order, then
  omitted sections); per slide `choices` (route id to the first frame after the choice, only on
  slides with `\route` buttons) and `continue` (`[{route, title, frame}]` on the last slide of a
  section: each route that continues elsewhere). `sb build --pdf` uses them
  (`slideblaster-md-alpha.md`, "Building").

## 8. Defaults taken (revisitable)

* Top-left y-down double geometry in the plan instead of exact rationals.
* Base16 for all bytes (2x size; revisit with binary frames).
* Core-side SHA-256 fingerprint; broker adds provider identity for its disk cache.
* Measurement advisory in W.
