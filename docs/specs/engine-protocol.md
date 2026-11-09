---
status: accepted
updated: 2026-07-23
---

# Engine protocol v1

The engine protocol is the target-independent command boundary shared by the
native and Wasm compositions. It is distinct from the browser
[host protocol](host-protocol.md).

The protocol identifier is the exact string `slideblaster.engine/1`. Every
request object is closed: missing or unknown fields are rejected. Arbitrary
source bytes use base16 rather than JSON text. Encoders emit lowercase base16;
decoders preserve the represented bytes exactly.

## Source snapshot

```json
{
  "revision": 0,
  "source": "61ff0a",
  "encoding": "base16"
}
```

`source` is authored bytes, not UTF-8 text. Revisions are unsigned and
monotonic. Byte offsets have the common native/Wasm v1 domain
`0..2147483647`; an offset outside it is rejected before target-dependent
conversion.

## Inspect

```json
{
  "protocol": "slideblaster.engine/1",
  "command": "inspect",
  "snapshot": {
    "revision": 0,
    "source": "610a",
    "encoding": "base16"
  }
}
```

A successful response returns the authoritative snapshot and derived
inspection:

```json
{
  "protocol": "slideblaster.engine/1",
  "ok": true,
  "response": "inspection",
  "snapshot": {
    "revision": 0,
    "source": "610a",
    "encoding": "base16"
  },
  "inspection": {
    "revision": 0,
    "bytes": 2,
    "lines": 2,
    "utf8": true,
    "fingerprint": "fnv1a64:089bdc07b544e7b2"
  }
}
```

The fingerprint is a diagnostic checksum, not a persistent identity or
security primitive.

## Exact replacement

```json
{
  "protocol": "slideblaster.engine/1",
  "command": "replace",
  "snapshot": {
    "revision": 4,
    "source": "616263",
    "encoding": "base16"
  },
  "edit": {
    "revision": 4,
    "start": 1,
    "end": 2,
    "expected": "62",
    "value": "7a"
  }
}
```

Spans are half-open byte ranges. The edit revision must equal the snapshot
revision, and `expected` must equal the exact bytes currently in the span. A
successful response has `response: "replacement"`, the successor snapshot,
its inspection, and this receipt:

```json
{
  "beforeRevision": 4,
  "afterRevision": 5,
  "start": 1,
  "end": 2,
  "removedBytes": 1,
  "insertedBytes": 1,
  "changed": true
}
```

This is a mechanically checked Slice 0 replacement. It is named
`AppliedExactReplacement` in Haskell and must not be described as a verified
semantic canvas edit.

## Bounded TikZ analysis

`analyze_tikz` opens the exact snapshot through the bounded lossless TikZ
reader:

```json
{
  "protocol": "slideblaster.engine/1",
  "command": "analyze_tikz",
  "snapshot": {
    "revision": 0,
    "source": "5c6e6f64652028616c706861292061742028312c3229207b68656c6c6f7d3b0a5c647261772028616c70686129202d2d2028392c38293b0a",
    "encoding": "base16"
  }
}
```

Opening is total. A supported source returns a successful `tikz_analysis` with
`analysis.state: "ready"` and a closed renderer-neutral plan. Malformed,
unsupported, ambiguous, or non-UTF-8 source returns a successful
`analysis.state: "syntax_only"` with a non-empty diagnostic list and the exact
unchanged snapshot.

A ready plan has exactly:

- `sourceRevision`, equal to the returned snapshot revision;
- `coordinateSpace: "slide_16x9_y_up"`;
- one `content_node` with validated ID, canonical decimal-string center, and
  plain Unicode content; and
- one `straight_connector` with canonical decimal-string start and end points.

Syntax-only diagnostics have the closed fields `category`, `code`, `span`, and
`message`. Categories are `malformed`, `unsupported`, or `ambiguous`; `span` is
either a half-open byte range or `null`. Messages are static explanations and
do not echo authored source.

## Verified bounded TikZ move

`move_tikz_node` carries the exact current snapshot plus a typed canvas lease:

```json
{
  "protocol": "slideblaster.engine/1",
  "command": "move_tikz_node",
  "snapshot": {
    "revision": 0,
    "source": "5c6e6f64652028616c706861292061742028312c3229207b68656c6c6f7d3b0a5c647261772028616c70686129202d2d2028392c38293b0a",
    "encoding": "base16"
  },
  "intent": {
    "revision": 0,
    "nodeId": "alpha",
    "destination": { "x": "4", "y": "5" }
  }
}
```

`intent`, `destination`, and every other request object are closed. The node ID
and decimal strings are admitted only through the shared Haskell constructors;
JSON numbers, exponents, units, excessive precision, and unknown fields are
rejected as `invalid_field`.

A successful `tikz_move` returns the authoritative successor snapshot, a move
receipt, and its current analysis. The receipt outcome is
`verified_change` only after provenance-guided projection, exact source checks,
full reparse/elaboration, and semantic equality. A semantic no-op returns
`unchanged`, preserves the original bytes, and does not advance the revision.
Candidate bytes and provenance are never exposed on the wire.

The complete frozen schema, diagnostic-code projection, browser lease rules,
and exact acceptance fixture are defined in
[the Slice 1 integration contract](slice1-roundtrip-integration.md).

## Errors

All failures use:

```json
{
  "protocol": "slideblaster.engine/1",
  "ok": false,
  "error": {
    "code": "stale_revision",
    "message": "The replacement targets a stale source revision",
    "details": {}
  }
}
```

Stable v1 categories are:

- `malformed_json`
- `unsupported_protocol`
- `unknown_command`
- `invalid_field`
- `stale_revision`
- `span_out_of_bounds`
- `expected_bytes_mismatch`
- `revision_exhausted`
- `source_locality_postcondition_failed`
- `local_postcondition_failed`
- `tikz_semantics_unavailable`
- `tikz_target_missing`
- `tikz_target_ambiguous`
- `tikz_projection_unsupported`
- `tikz_verification_failed`

TikZ staleness reuses `stale_revision`; a nested source-check failure reuses
the corresponding exact-replacement code. Verification failure details contain
only the stable reason `parse_or_elaboration_failed` or `semantic_mismatch`.
Errors do not include authored source, replacement bytes, or candidate bytes.
