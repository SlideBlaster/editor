# SlideBlaster Haskell Style

This file defines the code style for `slideBlaster2`. Its purpose is to make
source preservation, cross-target compilation, and review easier. Prefer
ordinary readable Haskell over cleverness.

## Language and compiler baseline

- Use `GHC2024` as the default language. Both the pinned native and Wasm
  compilers must support it.
- Enable extensions per module only when they make an invariant clearer.
- Shared packages must compile with both the pinned native and Wasm compilers.
- Use explicit export lists for every non-test module.
- Every module starts with a Haddock contract describing responsibility,
  invariants, and important relationships.

The common warning baseline is:

```text
-Wall
-Wcompat
-Widentities
-Wincomplete-record-updates
-Wincomplete-uni-patterns
-Wmissing-export-lists
-Wmissing-home-modules
-Wpartial-fields
```

CI may promote warnings to errors after both toolchains are pinned. Local builds
should retain useful warnings without depending on compiler-specific noise.

## Formatting and imports

- Format Haskell with Fourmolu.
- Format Cabal files with `cabal-fmt`.
- Treat HLint as review advice, not an automatic rewrite authority.
- Keep imports explicit and grouped: project modules, third-party modules, then
  `base`.
- Prefer qualified imports when a module exports common names or a domain
  vocabulary.
- Do not use import aliases that obscure the domain.

Example:

```haskell
import SlideBlaster.Source.Revision (Revision)
import qualified SlideBlaster.Source.Snapshot as Snapshot

import Data.Text (Text)
import qualified Data.Text as Text
```

## Names

- Modules use singular domain nouns:
  `SlideBlaster.Source.Snapshot`, not `Utils` or `Helpers`.
- Types and constructors use `UpperCamelCase`.
- Values and fields use `lowerCamelCase`.
- Predicates begin with `is`, `has`, or `can`.
- Conversions name both sides when ambiguity is possible:
  `utf16OffsetToByteOffset`.
- Include units in types, not variable suffixes.
- Avoid unexplained abbreviations. `CST`, `IR`, `UTF8`, and `JSFFI` are accepted
  project vocabulary.

No production module may be named `Common`, `Misc`, or `Util`. Put an operation
with the domain that owns its invariant.

## Data modelling

- Prefer algebraic data types over Boolean flags.
- Prefer `NonEmpty` when emptiness is invalid.
- Use newtypes for identifiers, revisions, offsets, dimensions, and units.
- Make invalid states unrepresentable when doing so remains understandable.
- Use GADTs, data kinds, or phantom types only to enforce a named invariant.
- Do not encode business rules solely in type-level machinery that ordinary
  diagnostics and tests cannot explain.
- Keep constructors private when construction must enforce validation.
- Derive `Eq`, `Ord`, `Show`, or `Generic` deliberately; do not derive a broad
  bundle by habit.

Prefer:

```haskell
data PatchState = Candidate | Verified

newtype SourceRevision = SourceRevision Word64

data Patch (state :: PatchState)
```

over a record containing `isVerified :: Bool`.

## Strictness

- Use strict fields for identifiers, offsets, revisions, counts, and other small
  scalar state.
- Introduce strict containers or evaluation only after profiling or when a
  retained thunk has a clear lifetime risk.
- Do not scatter bang patterns without a documented reason.
- The Wasm build has a memory budget; measure rather than guessing.

## Totality and partial functions

`scripts/lint-totality.py` enforces this section, and `make lint` runs it. It
ignores comments and string literals, so prose mentioning a forbidden name is not
a violation. Prose alone did not prevent these being written.

Do not use these in production code:

```text
head  tail  init  last  (!!)
fromJust
read
error
undefined
```

Use pattern matching, `NonEmpty`, `readMaybe`, and typed errors. A deliberately
unreachable case must be justified by a constructor or invariant and expressed
through a small internal function with a comment.

Tests may use partial helpers only when failure produces a clearer test failure
and the helper is not exported.

## Errors and diagnostics

- Expected failures use typed `Either`, `Validation`, or an explicit result ADT.
- Exceptions are confined to adapter boundaries and translated immediately.
- Do not expose `Either String` from a package API.
- Diagnostics have stable categories, a human message, and source locations when
  available.
- Preserve multiple independent parse diagnostics where possible.
- Distinguish unsupported syntax, malformed syntax, stale revisions, capability
  absence, and infrastructure failure.
- Never catch an exception and silently continue with altered semantics.

Example:

```haskell
data EditError
  = StaleRevision ExpectedRevision ActualRevision
  | ExpectedTextMismatch SourceSpan
  | ProjectionUnsupported SemanticId
  | VerificationFailed SemanticDifference
```

## Text, bytes, and positions

- Files enter and leave the system as strict or lazy `ByteString`, according to
  the API's streaming needs.
- Validated human text is `Text`; public APIs do not use `String`.
- Preserve the original byte stream for exact source operations.
- Byte offsets, Unicode scalar offsets, line/column positions, and browser
  UTF-16 offsets are distinct types.
- Conversion between offset units is explicit and can fail at invalid
  boundaries.
- Test CRLF, astral Unicode, combining marks, tabs, and a final line without a
  newline.

Never compare a browser editor offset directly with a UTF-8 byte offset.

## Source and syntax

- The lossless CST owns concrete spelling.
- Semantic nodes refer to syntax through typed provenance; they do not copy raw
  source merely for convenient printing.
- Parsers retain comments, whitespace, delimiter choice, and error regions.
- Unknown syntax becomes an opaque or error node containing all original tokens.
- Parsing user-authored source must return diagnostics rather than throw.
- If an explicit canonical printer is added, it is separate from exact source
  preservation and is never invoked by ordinary editing.
- Do not write a second ad-hoc parser to locate an edit region. Extend or query
  the authoritative CST.

## Semantic model

- The presentation and picture IR describe meaning, not browser DOM or concrete
  source.
- Layout and render plans are derived values and never gain persistence
  authority.
- Preserve ordered and repeated TikZ options even when effective meaning is
  derived into a map-like view.
- Unsupported constructs remain identifiable and source-backed.
- A reader/writer adapter may be partial, but it must report the exact unsupported
  boundary.

## Editing

- Canvas-derived semantic mutations enter as typed `EditIntent` values. CLI
  commands that perform the same semantic operation use the same intent.
- Direct code-pane or source-file authorship enters through a distinct
  revision-fenced source replacement operation. It reparses but may produce a
  syntax-only document snapshot.
- Preview and commit of a semantic edit use the same semantic operation.
- Candidate text edits carry an exact source revision and expected old bytes.
- Text edits are ordered, non-overlapping, and bounds-checked.
- Only the verification module may construct `VerifiedEdit`.
- A canvas-derived edit may enter source history or persistence only after
  semantic verification.
- A direct source replacement may enter source history and persistence after
  its revision check even when parsing or elaboration reports diagnostics.
- Projection failure has no state effects.
- A no-op creates no patch and no history entry.

Ordinary optics may update immutable semantic values. They are not a substitute
for a partial provenance-aware inverse transformation.

## Effects and capabilities

- Shared domain functions are pure by default.
- External effects enter through small records of functions. Slice 0 keeps
  target-only capabilities in its native and web adapters because shared
  semantics do not invoke storage. Promote shared capability vocabulary into
  `slideblaster-ports` only when a real vertical slice needs the same port from
  more than one composition.
- Public ports do not commit the project to an effect-system library.
- Interpreters translate platform exceptions into port error ADTs.
- A component receives only the capabilities it uses; avoid a global implicit
  environment.
- Storage and Git for one workspace must operate on the same abstract workspace
  root.

## Native and Wasm portability

- Shared packages import neither `GHC.Wasm.Prim` nor native-only process,
  filesystem-watch, or C-FFI libraries.
- All JSFFI lives in `slideblaster-adapter-web` or the Wasm executable.
- Prefer static foreign exports and a small asynchronous host-call surface.
- Do not retain `JSVal` callbacks unless their lifetime and release are explicit.
- Native subprocesses use argument arrays, never shell interpolation.
- Platform selection happens in Cabal components and composition roots, not with
  CPP throughout domain modules.
- Every new shared dependency must be compiled by both toolchains before the
  slice is considered complete.

## Protocols

- Host and engine protocols are versioned from their first message.
- Protocol ADTs live in `slideblaster-protocol`; adapters do not invent private
  wire variants.
- Decode unknown commands and versions into typed protocol errors.
- JSON is the initial wire encoding. Do not add a binary encoding without
  measurements.
- Protocol fixtures are shared by native and browser conformance tests.
- Avoid exposing internal record layout as a permanent wire contract.

## Browser host JavaScript

The browser host is handwritten JavaScript, not TypeScript.

- Use standards-based ES modules.
- Document public functions with JSDoc.
- Keep browser API calls in `hosts/web/src/capabilities`.
- Do not place presentation semantics or source-edit policy in JavaScript.
- Validate every message crossing the host boundary.
- Reject unknown capability names and malformed payloads.
- Convert thrown browser errors into structured error responses.
- Avoid mutable globals except the single versioned
  `globalThis.slideblasterHost` bootstrap object.
- Package every JavaScript dependency with the web artifact; do not depend on a
  CDN in production.

## Modules and package boundaries

- A module should own one coherent invariant.
- Split a module when independent responsibilities change for different reasons,
  not merely because it becomes long.
- Avoid package cycles and `hs-source-dirs` shared between packages.
- Package APIs expose domain operations, not internal constructors.
- `Internal` modules are permitted for implementation sharing but are not stable
  APIs.
- Update `PROJECT.md` whenever a module is added, removed, moved, or changes
  package ownership.

Dependency direction:

```text
source
  -> content / tex
  -> tikz / document
  -> engine / writers
  -> app / protocol
  -> web or native adapters
  -> executable composition
```

Ports contain capability vocabulary and may depend on small shared value types;
shared domain packages never depend on adapters.

## Comments and documentation

- Haddock describes the contract, not a line-by-line implementation.
- Comments explain invariants, non-obvious algorithms, and why a tempting
  alternative is unsafe.
- Do not keep changelogs in modules or architecture documents; Git owns history.
- Examples in Haddock should compile where practical.
- An exposed function documents failure cases and whether it preserves exact
  source.

## Tests

Use example tests for specific behaviour and property/state-machine tests for
laws.

Every source-editing package eventually covers:

- exact parse/render identity;
- parse recovery without token loss;
- stale revision rejection;
- expected-text mismatch rejection;
- non-overlapping patch application;
- untouched-byte identity;
- no-op behaviour;
- verification success and atomic failure;
- Unicode and line-ending boundaries.

Cross-target fixtures require native and Wasm to produce the same protocol
response for the same source and inputs.

Test names describe the law:

```text
prop_exactRoundTripPreservesBytes
prop_staleRevisionCannotCommit
prop_unownedBytesRemainIdentical
```

Do not weaken a property to match an implementation. Narrow the supported input
generator explicitly when the product subset is intentionally bounded.

## Review checklist

Before requesting review:

- Are source bytes and revisions still authoritative?
- Can invalid or unsupported input be preserved?
- Can an unverified edit reach history or storage?
- Did a native-only or browser-only dependency leak into shared code?
- Are errors typed and observable?
- Does the change cross a package or protocol boundary that needs documentation?
- Are tests derived from the contract?
- Were both applicable targets built?
- Is any JavaScript doing semantic work that belongs in Haskell?
- Is the implementation simpler than the invariant requires, or more complicated?
