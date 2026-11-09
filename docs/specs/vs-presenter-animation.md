---
status: proposed
updated: 2026-07-23
---

# Presentation scenes, notes, overlays, animation, and presenter

## Purpose and status

This slice supplies one coherent semantic backbone for presenting and exporting
an already elaborated deck:

```text
Picture + validated AnimationTimeline
  -> opaque Scene + picture-derived SceneAnalysis
  -> non-empty, unique-id Presentation
  -> non-empty audience-owned (frame, step) beats
  -> total presenter zipper
  -> synchronized audience and presenter-console projections
```

It implements the accepted fixed-geometry overlay, notes-cap, and shared-cursor
behavior from ADR 0018 and ADR 0019. It also represents the complete
target-neutral animation taxonomy required by the accepted SlideBlaster 2
product model.

The document remains **proposed** because concrete source spellings for
presentation metadata and timed animation, the coordinate/export meaning of
per-slide rotation, and browser playback behavior are not yet accepted product
contracts. The shared package does not claim source-format or browser-player
parity.

## User-visible vertical slice

Given an already elaborated deck:

1. each frame retains one coherent audience scene and an optional full notes
   scene;
2. overlay hooks and point pauses are derived from each scene's exact
   `Picture`/content tree instead of being supplied as parallel authority;
3. every element animation target is proven to belong to that scene;
4. audience overlay analysis derives a positive step count;
5. `flattenBeats` emits every `(frame, step)` in reading order;
6. next/back/home/end move one shared cursor and clamp at the ends; and
7. one projection returns an audience beat and a console containing that same
   beat, step-synchronized notes, next-beat preview, counters, and the unchanged
   host timer origin.

This is executable under native GHC and GHC Wasm. Opening windows, listening for
keys, reading a clock, and executing animations remain target adapter work.

## Ownership and authority

| Value                                                                          | Owner                       | Authority                                    |
| ------------------------------------------------------------------------------ | --------------------------- | -------------------------------------------- |
| authored bytes, raw overlay spelling, tri-dialect provenance                   | source/content packages     | persistence and concrete syntax              |
| `Picture`, `ElementId`, normalized `OverlayHook`, inline pause events, `Theme` | `slideblaster-canvas`       | picture and content meaning                  |
| `Scene` and derived `SceneAnalysis`                                            | `slideblaster-presentation` | coherent picture/overlay/animation ownership |
| deck/frame/notes aggregation and audience-capped beats                         | `slideblaster-presentation` | presentation meaning                         |
| timed animation tracks and schedules                                           | `slideblaster-presentation` | target-neutral animation meaning             |
| presenter zipper and synchronized projections                                  | `slideblaster-presentation` | navigation meaning                           |
| DOM/SVG, windows, clocks, keyboard input, animation player                     | web/native hosts            | ephemeral runtime effects                    |
| generated HTML, PDF, LaTeX, archives                                           | writer/export packages      | derived artifacts only                       |

Presentation does not parse overlay mini-languages, Markdown, LaTeX, HTML, or
document frontmatter. Canvas/source elaboration supplies normalized picture and
content values. Raw spellings and provenance remain with syntax.

## Scene coherence

`Scene` is opaque and is the only way a `Frame` or `Notes` value can carry a
picture, overlay analysis, and animation timeline.

```text
mkScene picture timeline
  -> collect picture elements in reading order
  -> collect each element OverlayHook
  -> collect recursive contentOverlayEvents
       (nested hooks + inline pauses + ready derived content)
  -> derive one OverlayProgram
  -> validate every animation track target
  -> validate every click trigger target
  -> Scene
```

This removes the former competing-authority state:

```text
Picture A + arbitrary OverlayProgram B + AnimationTimeline targeting C
```

An empty picture with no content events therefore always has one beat and no
overlay hooks. There is no `mkFrame` or `mkNotes` argument through which a
caller can attach a fabricated `OverlayProgram`.

`SlideSurface` is local to the scene and is always valid. A `PictureElement`
used by a property track or click trigger must occur in that scene's
`pictureElements`; otherwise `mkScene` returns a typed error naming the
animation and missing element.

## Presentation model

`Presentation` contains deck metadata and `NonEmpty Frame`. The constructor is
private. `mkPresentation` accepts `NonEmpty Frame` and rejects the first
duplicate stable `FrameId`, because duplicate IDs would make `SurfaceAddress`
and `ElementAddress` ambiguous.

An empty workspace or a draft that has not elaborated is application state, not
a semantic `Presentation`. This division makes all presentation consumers
total:

- `presentationFrames :: Presentation -> NonEmpty Frame`;
- `flattenBeats :: Presentation -> NonEmpty Beat`; and
- `startPresenter :: TimerOrigin -> Presentation -> PresenterState`.

A `Frame` contains:

- a stable non-blank `FrameId`;
- navigation title metadata;
- normalized display rotation;
- one validated audience `Scene`; and
- optional `Notes`, which wraps one validated notes `Scene`.

Aspect ratio is positive and normalized. Rotation is stored as rational degrees
normalized to `[0,360)`. This slice does not decide which angles an editor
offers, whether rotation changes logical coordinates, source spelling, or
target-specific mapping.

### Stable cross-surface addresses

```text
SurfaceAddress = FrameId × (AudienceSurface | NotesSurface)
ElementAddress = SurfaceAddress × ElementId
```

Addresses contain no slide index, source span, DOM handle, or render-plan
identifier. Reordering preserves them. Presentation-level duplicate-frame
validation and canvas-level duplicate-element validation make them
unambiguous.

## Overlay programs and fixed geometry

Canvas owns normalized visibility hooks and source-order content events.
Presentation's `Scene` traverses:

- each object-level `elementOverlay`;
- recursive inline `OverlayContent`;
- list-item overlay hooks;
- `OverlayPauseContent`;
- ready nested include/citation/table content; and
- no unresolved, loading, failed, opaque, or unsupported derived substitute.

The normalized overlay algebra remains:

- a hook records one normalized visibility reference;
- a next pause advances the current reading-order floor;
- an explicit pause selects an elaborated step;
- a sequence threads the pause floor left-to-right; and
- parallel scopes share their incoming floor without leaking it.

The derived count is always at least one. Overlay changes visibility only.
Layout and measurement use maximal union geometry once; advancing a build never
requests re-layout.

### Notes cap law

Only the audience scene's program is consulted by `frameStepCount` and
`flattenBeats`. Notes render at `beatStep`, but notes hooks, pauses, and timed
animations beyond the audience final step have no audience beat on which to
appear. Notes cannot add presenter clicks.

## Overlay beats are not timed animation

```text
Scene overlay analysis
  -> derives discrete presenter beats
  -> next/back changes the selected beat

AnimationTimeline
  -> schedules tracks within an existing beat
  -> never changes flattenBeats or presenter navigation
```

`OnOverlayStep n`, a click trigger on step `n`, or an explicit offset on step
`n` selects an existing beat. None creates that beat.

## Timed-animation contract

“Pure executable” means construction, validation, scheduling, endpoint sampling,
or reduced-motion policy is implemented. It does not mean browser pixels
animate.

| Capability                                                                    | Semantic representation                                                          | Pure executable behavior                                                                                  | Host/source status                     |
| ----------------------------------------------------------------------------- | -------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- | -------------------------------------- |
| entrance, emphasis, exit, motion, transition                                  | closed `AnimationEffect` taxonomy                                                | classification, compatibility inspection                                                                  | player and syntax deferred             |
| opacity, translation, motion path, rotation, two-axis scale, fill/stroke RGBA | typed `PropertyTrack` values                                                     | strictly increasing keyframe offsets and deterministic endpoints                                          | interpolation deferred                 |
| line/cubic motion paths                                                       | explicit start plus non-empty segments                                           | deterministic initial/final position                                                                      | player deferred                        |
| beat entry                                                                    | `OnFrameEnter` / `OnOverlayStep`                                                 | resolves to an existing beat                                                                              | host receives exact beat               |
| direct click                                                                  | `OnTargetClick beat target`                                                      | beat and scene-owned click target validated                                                               | host receives exact target             |
| explicit offset                                                               | `AtTimelineOffset beat milliseconds`                                             | non-negative beat-local offset retained                                                                   | host receives exact offset             |
| with/after                                                                    | previous or named prior animation                                                | backward-only dependency validation; resolved schedule names exact dependency and preserves with vs after | host does not infer from list position |
| delay/duration                                                                | non-negative delay, positive duration                                            | zero duration rejected                                                                                    | host clock deferred                    |
| easing                                                                        | linear, ease curves, cubic Bézier, stepped                                       | validated representation                                                                                  | interpolation deferred                 |
| repeat/direction/fill                                                         | once/count/forever; forward/reverse/alternate/alternate-reverse; four fill modes | explicit retention; old convenience constructor defaults only to forward                                  | player deferred                        |
| reduced motion                                                                | host preference plus preserve/complete/omit-decorative policy                    | `PlayAnimation`, `ApplyFinalAnimationState`, or `OmitAnimation`                                           | preference capability deferred         |

### Schedule authority

`AnimationTrigger` retains authored intent. `AnimationSchedule` is a validated
derived view:

```text
AnimationSchedule
  { existing beat
  , StartAtBeatEntry
      | StartOnTargetClick target
      | StartAtTimelineOffset offset
      | StartWithAnimation exact-prior-id
      | StartAfterAnimation exact-prior-id
  }
```

`WithPrevious` and `AfterPrevious` resolve to the exact preceding ID.
`WithAnimation` and `AfterAnimation` must name an earlier timeline entry.
Duplicate IDs, missing previous entries, forward references, and cycles are
unrepresentable in a validated `AnimationTimeline`. A playback host receives
the distinction directly; it must not invent start semantics.

## Presenter state and views

`PresenterState` is a private zipper over the non-empty result of
`flattenBeats`.

- startup is total;
- next/back clamp at final/first beat;
- home/end select first/final beat;
- navigation preserves the supplied `TimerOrigin`;
- navigation changes no presentation, frame, scene, or picture; and
- no public constructor can create a beat outside its audience count.

`projectPresenterViews` atomically creates:

- `AudienceView` containing the current audience beat; and
- `PresenterConsoleView` containing that same beat, current notes, next
  audience beat, slide/step counters, and timer origin.

The host calculates elapsed time from its monotonic clock. The shared model
stores no wall-clock time and performs no effects.

## Static export compatibility

`Beat` is abstract. Writers derive stable identity only from:

```text
(frameIdText (beatFrameId beat), overlayStepNumber (beatStep beat))
```

`beatAnimations` returns only animations scheduled for that existing beat. A
writer can serialize a supported runtime animation, apply a deterministic
static endpoint, or emit a scoped compatibility diagnostic. It must not silently
discard animation meaning or manufacture a frame/step key.

## Failure behavior

- blank frame and animation identities are typed construction errors;
- a semantic presentation cannot be empty;
- duplicate frame identities are rejected;
- foreign animation track and click targets are rejected by `mkScene`;
- zero aspect dimensions, zero duration, invalid counts/intervals, single
  keyframes, and non-increasing offsets are rejected;
- transitions targeting picture elements are rejected;
- duplicate animation IDs and non-prior dependencies are rejected;
- navigation at a boundary returns unchanged state; and
- absent source projection is surfaced by its adapter, never guessed here.

## Package and target boundary

Public modules are:

- `SlideBlaster.Presentation` (facade);
- `SlideBlaster.Presentation.Address`;
- `SlideBlaster.Presentation.Animation`;
- `SlideBlaster.Presentation.Model`;
- `SlideBlaster.Presentation.Overlay`;
- `SlideBlaster.Presentation.Presenter`; and
- `SlideBlaster.Presentation.Scene`.

The package depends only on `base`, `text`, and `slideblaster-canvas`. It imports
no browser, filesystem, process, clock, JSFFI, or native-only library.

## Executable laws

The package tests prove:

1. a scene derives object, nested-content, and pause overlay meaning;
2. an empty picture cannot be paired with fabricated overlay analysis;
3. foreign property-track and click targets fail scene construction;
4. `Presentation` is non-empty and rejects duplicate `FrameId`;
5. notes cannot extend audience beats;
6. `flattenBeats` preserves frame/step reading order and is non-empty;
7. presenter startup is total and navigation clamps correctly;
8. audience/console projections share one current beat;
9. notes, preview, counters, and timer origin match that cursor;
10. typed tracks reject invalid offsets and sample deterministic endpoints;
11. timelines reject duplicate and forward dependencies;
12. click, explicit offset, with, and after schedules retain distinct meaning;
13. playback direction is explicit;
14. timed animation never adds a beat; and
15. reduced-motion disposition preserves essential final meaning.

## Deliberately deferred

- presentation/frontmatter and animation concrete syntax;
- provenance-guided edits for metadata, notes, overlays, or animations;
- per-slide rotation coordinate and export semantics;
- browser/native presenter window composition and synchronization transport;
- browser animation execution and interpolation;
- authoring controls, timeline UI, and accessibility UI;
- animation capability negotiation for each writer;
- diagnostics for notes content staged beyond the audience cap; and
- remote presenter control, annotations, and notes-extended builds.
