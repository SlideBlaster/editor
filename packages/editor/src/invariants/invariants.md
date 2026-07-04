# format invariants

The five laws from `design/format/slideblaster-md.md`, encoded as reusable
predicates so the same statements drive golden and property-based tests. They are
the real specification of the format spine.

- **`modelRoundTrips(doc)`** — invariant 1: `fromMarkdown(toMarkdown(model)) == model`.
- **`textIsCanonical(text)`** — invariant 2: `toMarkdown(fromMarkdown(text)) == text`
  (deterministic canonical form).
- **`identityPreserved(doc)`** / `nodeNames(doc)` — invariant 4: node names survive
  every round-trip, in order.

Invariant 3 (locality) and invariant 5 (order independence) are demonstrated
directly in `invariants.test.ts` at the serialization layer: editing one statement
regenerates only its span, and two edits to different statements commute to the same
canonical text. `stableStringify` gives order-insensitive structural equality for
the plain-data model.
