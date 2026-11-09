---
status: accepted
updated: 2026-07-28
---

# STR-007 implicit-canvas `.slide` trial

This document records a **provisional P0 trial**, not a permanent or versioned
SlideBlaster document format. It exists to test a lossless multi-slide parent
container around the bounded TikZ canvas adapter using `temp/demo.slide`.

## Admitted parent form

A ready document has one `deck` header with opaque balanced metadata, followed
by one or more `slide ID "title" (metadata) """body"""` records. An optional
`note """body"""` belongs to the immediately preceding slide. Exact source
bytes and half-open parent spans are authoritative; no printer or
canonicalization exists. Malformed structure, duplicate slide IDs, duplicate
node IDs within a slide, and unresolved admitted connector targets make the
whole document syntax-only without changing bytes.

Literal triple-quote sequences inside raw bodies are unsupported in this P0
trial. Such input is read-only/syntax-only; no escaping convention is claimed.
Metadata interiors and unsupported TikZ statements/properties/content are
retained exactly and remain opaque or read-only.

## Implicit canvas and verified edits

Each audience body is analyzed as one implicit bounded TikZ canvas at the
parent revision. Repeated direct-position nodes and simple node-to-node `--`
paths are admitted. Nested mixed node payload bytes remain one exact
source-backed text run. Notes are retained as a distinct empty semantic notes
surface and are not editable in this trial.

A writable direct-coordinate node move must pass the displayed paint/surface lease,
retain the same recognized authored anchor port, parent revision and expected
bytes, bounded child projection, exact parent-span replacement, complete parent
reparse, and intended semantic destination check.
Only the verified coordinate slots change. Any stale, unsupported, malformed,
or semantically mismatched successor changes neither source nor history.

## Navigation and New Slide

Haskell owns ordered stable frame IDs/titles, active frame/index, previous/next
availability, selection/gesture reset, and active paint selection. Navigation
changes no source revision or history.

`new_slide` carries only the current revision. Haskell inserts one deterministic
minimal empty slide after the active slide (and its optional note), choosing the
first unused `slide-N`, preserving inferred LF/CRLF, and recording exactly one
history step. The new slide becomes active. Undo restores exact prior bytes and
the prior active frame; redo selects the recreated frame when available.

The browser host loads the tracked exact demo fixture, projects Haskell's
navigator/actions, and forwards surface-correlated raw facts. It does not parse
decks, mint IDs, calculate revisions, choose insertion text, or own navigation
or source semantics.

## Deliberate exclusions

This trial does not establish a permanent file extension or grammar, notes
editing/rendering, arbitrary TikZ expansion, complex path admission, structured
mixed-content painting, slide deletion/reorder, or a general deck formatter.
Any promotion or syntax change requires a separate product-owner decision.
