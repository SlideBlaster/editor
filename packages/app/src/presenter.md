# presenter (presenter.ts)

Live two-window presenter mode (ADR 0019). "Present" opens an **audience** window (the
current slide, for the projector) and a **presenter console** (the current slide's notes
sidecar + next-slide preview + a slide/step readout + an elapsed timer), driven by one
shared cursor so a single "Next" advances both.

## The beat list

`buildBeats(frames, renderAt, stepsOf)` flattens the deck into an ordered list of
**beats** — one per `(frame, step)`. For each frame it emits `1..stepsOf(picture)` beats
(**cap to slide**: the step count is the audience slide's own; the notes never add
steps, ADR 0019), rendering the slide and its `notes` sidecar at the **same** step. This
is the same per-step frame list export uses, plus the notes surface. Pure and
DOM-free — `renderAt` (async) is where layout + rendering happen, so the caller resolves
each picture's step-invariant layout once and reuses it across steps.

## Presenting

`present(deps)` opens the console window **synchronously** (before its first `await`) so
the pop-up rides the user gesture, writes a "preparing" placeholder, then `prepare()`s
(compile tables/citations across the deck), builds the beats, and writes the real
self-contained console document. The console's **Open audience display** button opens the
audience window (a second in-window gesture) and writes the embedded audience document.

Returns `{ok:true}`, or `{ok:false, reason}` where `reason` is `'blocked'` (console
pop-up blocked), `'empty'` (no beats), or `'error'` (rendering threw; `message` set).

## Synchronisation

Both windows share one integer cursor over the beat list via `BroadcastChannel('sb-presenter')`:

- A key/click in either window moves the cursor and posts `{t:'goto', cursor}`; both
  windows repaint to that cursor. A `BroadcastChannel` does not echo to its sender, so
  there is no feedback loop.
- A newly opened window posts `{t:'hello'}`; the other replies with its current
  `{t:'goto', cursor}`, so the audience opens on whatever step the console is on.
- Advancing steps within a slide, then rolls to the next slide's first step (Beamer
  behaviour); Home/End jump to the first/last beat. `f` toggles fullscreen on the
  audience window.

## Self-contained documents

Both documents inline the full deck stylesheet (`deckCss` = `slideStylesheet()` + the
active theme/furniture CSS passed in + `SLIDE_TYPE_CSS` + `KATEX_CSS`) and bake the
rendered slide HTML in, so the show survives the editor window closing. The audience
document is embedded as a string inside the console document (so the console can write it
into the audience pop-up). Embedded JSON/strings have every `<` replaced by its `\u`
escape so slide HTML containing a closing `script` tag cannot break out of the
`<script>` context.

Furniture HTML (per-slide page numbers, ADR 0017) is not yet baked per beat — a shared
follow-up with the standalone export, which has the same gap. Theme _CSS_ is applied, so
colours and fonts match the live canvas.
