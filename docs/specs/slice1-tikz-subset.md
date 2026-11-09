---
status: proposed
updated: 2026-07-30
---

# Slice 1 literal TikZ subset

This specification is the executable boundary of the first semantic
source-to-canvas-to-source proof. It is deliberately smaller than the proposed
T1 surface in `design/format/tikz-subset.md`. Supporting this grammar does not
claim support for general TikZ, TeX expansion, or the complete legacy editor.

## User-visible proof

Given a bare TikZ picture body containing one named node followed by one
straight connector, both the native and Wasm compositions can eventually:

1. retain the authored bytes exactly;
2. derive one semantic picture and renderer-neutral plan;
3. move the node with a typed intent;
4. replace only the node's direct decimal coordinate token or tokens;
5. reparse and verify the intended semantic picture; and
6. observe the connector start follow the moved node without rewriting the
   connector statement.

This package implements the pure shared work node only. Browser, CLI, protocol,
history, and persistence integration remain separate Slice 1 work nodes.

## Literal grammar

`trivia` is zero or more spaces, horizontal tabs, CR, LF, or `%` comments
ending at LF or end of input. Trivia is admitted only between grammar tokens
and is always retained byte-for-byte.

```text
picture   ::= trivia node trivia connector trivia EOF

node      ::= "\node" trivia "(" id ")" trivia "at" trivia point
              trivia "{" content "}" trivia ";"

connector ::= "\draw" trivia "(" id ")" trivia "--" trivia point
              trivia ";"

point     ::= "(" trivia decimal trivia "," trivia decimal trivia ")"
id        ::= [A-Za-z_][A-Za-z0-9_-]*
decimal   ::= [+-]? DIGIT+ ("." DIGIT+)?
```

The connector `id` must equal the node `id`. The node content is valid UTF-8
containing balanced groups; an empty content body is valid. The closing brace is
the one that matches the opening brace at the same depth, and the scan honours
TeX's own rules: a backslash makes the following byte ordinary, so `\{` and `\}`
are content rather than delimiters, and `%` comments out the rest of its line so
a brace after it is not a delimiter. An unbalanced group is malformed, because
the statement never ends. The decimal reader
admits at most 18 digits total and at most 9 fractional digits. Decimal
spelling is concrete syntax; semantic equality normalizes leading plus signs,
leading zeros, trailing fractional zeros, and negative zero.

These exact restrictions keep the first inverse rule unambiguous. They are not
assertions about what later TikZ packages should support.

## Explicit exclusions

The reader does not assign writable semantics to:

- `tikzpicture` wrappers or any other environment;
- node or draw options;
- more, fewer, or reordered statements;
- multiple nodes, duplicate identities, or multiple connectors;
- named, relative, polar, calc, unit-bearing, or exponent coordinates;
- connector operations other than one straight `--` segment;
- an identifier outside `[A-Za-z_][A-Za-z0-9_-]*`.

The authority for what content may contain is `../../../design/format/node-content.md`
and, for the document around it, `../../../design/format/slideblaster-md.md`. A
presentation is a markdown file whose slides are fenced `slide` blocks holding a
TikZ-superset picture; node content is the tri-dialect those specify. Neither the
file nor a node has an outermost notation, and nothing compiles the input as a LaTeX
document. The dialect table and the worked corpus from that specification are
checked as laws in `slideblaster-syntax`, so a spelling that drifts from them fails
the build rather than only the prose.

Node content is delimited here but not interpreted here. Its meaning is supplied
by `slideblaster-syntax`, which reads it as one mixed language of LaTeX, Markdown
and inline HTML, expands LaTeX2e macro definitions, and lowers the result to
style-resolved runs. The three notations are co-equal: none is the document's
language, and none needs an environment or fence to be written. Content
outside that package's supported subset is reported as opaque and reprinted
exactly; it does not make the picture unavailable, because a slide should not
become unopenable over one unsupported fragment.

Content style is editable. A style command names a range of rendered characters
and one property, and the construct it lands on is re-spelled in the notation that
authored it: `\textbf` inside LaTeX, `<strong>` inside HTML, `**` inside Markdown.

Where nothing encloses the selection, the notation of the content being wrapped
decides, and where that is mixed the command carries the theme's default. The
default is a required field on the wire: a codec that supplied one would be giving
a second, silent opinion about a theme setting.

A property the chosen notation cannot spell is written in one it admits rather than
refused, because the author could have written that by hand here -- LaTeX has no
strikethrough, so `\textbf{a}` struck through becomes `\textbf{<s>a</s>}`. Only a
property that no admissible notation can express is refused.

A command sets a property, clears it, or toggles it. Which of set or clear a
toggle means is decided from the tree, not by the interface, because deciding
needs to know which constructs the selection covers. Clearing removes every
assertion of the property inside the selection, including the author's own
commands there, and states the opposing value only when the property is inherited
from outside the selection and so cannot be removed. Toggling is therefore not an
inverse of itself: turning a property off discards which construct asserted it,
and exact restoration is history's job.

Unsupported, malformed, and ambiguous input remains the exact authoritative
source and is represented by one source-backed opaque region with a diagnostic.
No fallback geometry is produced. This is the bounded form of the
`out-of-subset-hard-error` contract.

The supported CST is also source-backed rather than printer-backed. It retains
the whole-document span, both statement spans, and the x/y token spans against
the exact `SourceBufferSnapshot`. Delimiters, comments, whitespace, content,
and all gaps are therefore concrete leaves of that backing source even when
the semantic model has no reason to decode them. Exact output reads the backing
bytes; it never reconstructs source from semantic values.

## Snapshot and reader laws

**SB2-S1-001 Exact identity.** Opening and inspecting a source never changes a
byte. The exact output is the `SourceBufferSnapshot` bytes, not a printer.

**SB2-S1-002 Recovery.** Every input produces a document snapshot. A supported
input is semantically ready. A malformed, unsupported, or ambiguous input is
syntax-only, retains all bytes in an opaque region, and carries a typed
diagnostic.

**SB2-S1-003 Direct authorship.** A revision-fenced direct source replacement
advances the authoritative source even when the replacement is invalid. Such a
snapshot has no writable canvas semantics. A stale direct replacement is
rejected atomically.

## Semantic and render model

The semantic `Picture` contains exactly:

- one `Node` with validated identity, direct `Point`, and decoded UTF-8 content;
- one `Connector` from that node identity to a direct absolute `Point`.

The minimal `RenderPlan` contains a positioned content node and a straight
segment. Its connector start is resolved from the node's current semantic
point each time the plan is derived. The plan is renderer-neutral and carries
neither DOM values nor persistence authority.

## Move transaction

`MoveNode` contains the source revision painted by the caller, a validated node
identity, and the intended destination point.

**SB2-S1-004 Verified move.** Applying a non-no-op move:

1. checks the intent revision against the authoritative snapshot;
2. requires a semantically ready document and an unambiguous matching node;
3. computes the intended after-picture;
4. obtains the node's field-grained direct x/y token spans from the
   authoritative parse;
5. constructs one candidate exact replacement at that revision with the exact
   old bytes;
6. uses `slideblaster-source` to check revision, bounds, expected bytes, and
   prefix/suffix locality;
7. reparses and elaborates the candidate bytes with this same reader; and
8. returns the successor only if its `Picture` equals the intended
   after-picture.

Candidate and verified phases are private package states. No caller can persist
or render a candidate as an accepted semantic edit.

**SB2-S1-005 Token locality.** If only x or y changes semantically, only that
decimal token is canonically rewritten. If both change, both decimal tokens are
rewritten while every byte between and outside them is copied exactly.
Comments, whitespace, commas, delimiters, content, connector bytes, CRLF, and
all other unowned bytes remain identical.

Canonical decimal output has no leading plus, no redundant leading or trailing
zeros, and uses `0` for semantic zero. It is used only for a coordinate field
changed by this move.

**SB2-S1-006 Atomic failure.** Stale, unavailable, unsupported, ambiguous,
missing-target, source-check, or semantic-verification failure returns a typed
error and no successor snapshot. The input value remains unchanged.

**SB2-S1-007 No-op.** Moving a node to its existing semantic point returns the
same snapshot without canonicalizing its spelling or advancing its revision.

## Deliberately deferred

- browser canvas events and Wasm protocol commands;
- native CLI commands;
- source history, undo/redo, and durable persistence;
- measured node boxes, anchor-border intersection, and layout constraints;
- connector reshape intents;
- a general structural TeX grammar and larger T1/T2 subsets;
- any whole-document or statement formatter.
