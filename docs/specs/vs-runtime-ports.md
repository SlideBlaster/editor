---
status: proposed
updated: 2026-07-23
---

# Vertical slice: native and browser runtime ports

## Purpose

This slice gives the Haskell application one target-neutral vocabulary for
effects that are now required by real canvas, presenter, export, and
working-copy paths:

```text
shared Haskell request
  -> one small capability record
  -> native or browser interpreter
  -> typed result/failure
  -> revision/correlation check in Haskell
```

It is a ports-and-adapters seam, not an effect-system framework. Components
receive the individual records they use. There is no implicit global
environment, free-monad instruction tree, browser value in shared state, or
platform branch inside a semantic package.

The user-visible demonstration for the implemented subset is:

1. validate one workspace-relative path with the same rules on both targets;
2. list/read exact workspace bytes through a native or browser interpreter;
3. conditionally replace an existing native file only when exact expected bytes
   still match;
4. request Git version/status through a structured request on native;
5. preserve a render-owned measurement ticket and semantic key without
   inventing a host request type, while reporting the current host mismatch;
   and
6. emit one structured log through either host.

Every other capability has its final module/type home and an explicit
unavailable provision. File presence is not reported as feature completion.

## Authority and dependency direction

The ports package reuses domain values instead of creating wire-shaped copies:

| Concern                    | Authoritative package/value                                                     | Port responsibility                                 |
| -------------------------- | ------------------------------------------------------------------------------- | --------------------------------------------------- |
| source persistence         | `slideblaster-source` / `SourceBufferSnapshot`                                  | exact expected-byte handoff only                    |
| content measurement        | `slideblaster-render` / `MeasurementBatch`, `MeasurementResult`                 | execute measurements; preserve ticket/key           |
| presenter cursor and notes | `slideblaster-presentation` / `PresenterState`, `PresenterViews`, `TimerOrigin` | windows, navigation transport, monotonic timer only |
| deterministic artifacts    | `slideblaster-export` / `DeterministicArtifact`                                 | download/delivery only                              |
| rendered PDF plan          | `slideblaster-export` / `PrintPlan`                                             | print-dialog execution only                         |
| workspace ZIP plan         | `slideblaster-export` / `ArchivePlan`                                           | deterministic compression only                      |
| compiler primary input     | `slideblaster-source` / `SourceBufferSnapshot`                                  | execute selected compiler only                      |
| compiler auxiliary input   | `slideblaster-export` / `WorkspaceEntry`                                        | expose exact path/bytes to compiler only            |

Source remains persistence authority. Render measurements and plans remain
derived. Presenter windows do not own a second deck or cursor. An export port
cannot reclassify compatibility loss, manufacture a PDF result from print HTML,
or label arbitrary bytes as a ZIP.

The dependency direction is:

```text
source + canvas + presentation + render + export
                        |
                        v
                slideblaster-ports
                    /          \
                   v            v
             native adapter   web adapter
```

No semantic package depends on an adapter.

## Public module map

| Module               | Contract                                                                       |
| -------------------- | ------------------------------------------------------------------------------ |
| `SlideBlaster.Ports` | facade re-exporting the complete port vocabulary                               |
| `.Capability`        | named whole-port provision/absence and typed runtime failures                  |
| `.Workspace`         | workspace identity, safe relative paths, exact reads, conditional writes       |
| `.Git`               | validated names/messages and a closed structured Git request/result vocabulary |
| `.Measurement`       | render-owned batches/results and correlation-preserving adapter helper         |
| `.Presenter`         | popup handles and sequenced navigation-channel messages only                   |
| `.Export`            | download, print, and archive execution over export-owned plans                 |
| `.Compile`           | typed LaTeX-fragment, TikZ-picture, and LaTeX-project compiler jobs            |
| `.Clock`             | presentation-owned monotonic `TimerOrigin`                                     |
| `.Log`               | closed log levels and scalar structured fields                                 |

Target bridge modules are:

- `SlideBlaster.Adapter.Native.Port`;
- `SlideBlaster.Adapter.Web.Port`.

Existing narrow adapter modules remain implementation details used by those
bridges. The ports package imports neither one.

## Capability provision

An entire port is either:

```text
CapabilityProvided port
CapabilityUnavailable (capability, reason)
```

Unavailable reasons distinguish:

- not implemented for this composition;
- host protocol operation missing;
- external dependency missing; and
- permission unavailable.

An advertised port may still encounter a runtime transport, protocol,
infrastructure, or host-rejection failure. That distinction matters:
“browser protocol v1 has no print operation” disables Print before dispatch;
“the print operation existed but the popup was blocked” is a runtime result.

Partially implemented ports expose operation support explicitly:

- storage distinguishes arbitrary-byte fidelity from UTF-8-text-only storage;
- storage distinguishes conditional create and conditional replace;
- Git exposes support per `GitOperation`;
- compiler adapters expose support per `CompileKind`;
- a future structured measurer may reject an individual request it cannot
  faithfully measure.

Command availability must consult those operation-level contracts. The
presence of a read-only storage record does not enable Save.

## Workspace identity and paths

`WorkspaceId` is a composition-scoped identity. A Storage/Git pair for one
working copy carries the same identity. It is not a host directory, URL,
credential, or durable project identifier.

`WorkspacePath` has a private constructor. `mkWorkspacePath` accepts only a
non-empty normalized relative POSIX path:

- at most 240 Unicode scalar values;
- no leading `/`;
- no `\`, NUL, or control character;
- no empty, `.`, or `..` segment; and
- no first segment shaped like a Windows drive (`C:`).

The spelling and Unicode are otherwise retained exactly. Adapters receive
validated segments and resolve them beneath their injected workspace root.
Native traversal rejects symbolic-link entries rather than following them
outside the lexical root. `.git` and descendants are omitted from user
workspace listing.

These checks prevent lexical path traversal. The portable native adapter does
not claim a kernel-level directory capability or protection from hard-link and
mount changes; that limitation is the same portability trade-off documented
for native standard-library persistence.

## Exact storage and source save

Reads return:

```text
Right Nothing        path is absent
Right (Just bytes)   exact file bytes
Left error           capability/infrastructure/safety failure
```

Writes never accept an unconditional mode:

```text
ConditionalWrite path ExpectAbsent       successorBytes
ConditionalWrite path (ExpectExact old)  successorBytes
```

The adapter must either preserve the condition or return
`StorageConditionalWriteUnsupported` without mutation. Conflict errors contain
the path, not the compared source bytes.

`saveSourceSnapshot` consumes an expected and successor
`SourceBufferSnapshot`. It:

- derives the external condition from exact expected bytes, never revision
  alone;
- rejects changed bytes whose process-local successor revision is not newer;
- treats byte-identical content as an allowed no-op; and
- delegates the resulting expected-byte request to the storage interpreter.

The current native bridge implements sorted traversal, exact read, and
expected-byte replacement through the existing ordinary Haskell adapter. It
inherits that adapter's documented narrow reread-to-rename race and does not
claim atomic compare-and-exchange against external processes. Conditional
creation is unavailable.

The current browser host implements UTF-8-compatible text list/read and an
unconditional string write. The bridge uses list/read and returns UTF-8 bytes.
Its `storageArbitraryBytesSupport` is unavailable, so binary asset consumers
must not treat the browser text store as an exact binary working copy.
It deliberately does not call the write operation: an unconditional
`localStorage.setItem` cannot satisfy `ExpectAbsent` or `ExpectExact`. Both
browser write modes remain unavailable until a versioned host operation
performs the comparison and write as one capability action. This is an
intentional source-safety failure, not missing glue.

## Structured Git

`GitRequest` is a closed sum:

```text
version
status
initialize branch
stage non-empty paths
commit message
log positive-limit
create-branch branch
checkout branch
pull remote branch
push remote branch
```

There is no constructor containing an executable name, argument string, shell
pipeline, redirection, environment assignment, or credential. Branch/remote
names use a conservative validated grammar; stage paths are `WorkspacePath`;
commit messages are non-blank and NUL-free. Native interpreters map each
constructor to a process plus argument array.

`gitPort` wraps every interpreter. An unavailable operation returns
`GitOperationUnsupported` without invoking the target, and a mismatched
successful response is rejected at the shared boundary rather than relying on
each caller to remember the check. The first native bridge
executes only version and porcelain-v1 status via the existing native Git
adapter. The status payload remains an opaque typed snapshot until a complete
porcelain parser is promoted; it cannot be executed as a command. Initialize,
stage, commit, log, branch, checkout, pull, and push are represented but report
operation-level unavailability. The current browser protocol has no Git
operation, so its entire Git provision is unavailable.

Storage and Git must be constructed with the same `WorkspaceId` and underlying
root. A later composition test must prove both visibility directions:
storage writes are visible to Git, and Git checkout changes are visible to
storage.

## Measurement

`MeasurementPort` consumes one render-owned `MeasurementBatch` and returns
render-owned `MeasurementResult` values. It does not expose a second
measurement key, ticket, content, typography, or size type.

Each batch carries dialect-free recursive `RenderContent`, per-text-run
`RenderTypography`, and a `ResourceManifest`. Typography names exact embedded
font resources; the host must use those bytes rather than a system fallback.
`measurementResultForRequest` can reconstruct a result only from the original
request key, batch ticket, and a validated canvas `Size`.

The current DOM host call accepts one plain string, one CSS font shorthand, and
an optional pixel width. It cannot:

- mount the batch's embedded font resources or prove that they loaded;
- retain mixed per-run typography;
- measure structured lists, tables, math, citations, or images; or
- consume the render resource manifest.

Flattening `RenderContent` and naming a best-effort system font would make a
derived layout depend on silent fallback. The browser bridge therefore does
not invoke the legacy `measure.text` wrapper and advertises Measurement as
unavailable. The next measurement slice must add a versioned host operation
whose request carries structured render content plus required resource/font
identities and whose response is correlated to the original ticket/key.

No native measurer is selected either. A stale ticket remains rejected by
`completeMeasurements`; no future port can make a measurement authoritative.

## Presenter windows and channel

Presentation semantics remain in `slideblaster-presentation`. The ports own
only:

- validated opaque presenter session identities;
- audience versus console window requests;
- opaque host window handles;
- focus and close actions; and
- sequenced Next/Back/Home/End navigation messages.

Haskell applies a received navigation action to `PresenterState` and projects
both views atomically. The channel does not transmit a mutable deck, arbitrary
JavaScript, source, or a freely constructible beat. Render mounting is a
separate browser boundary.

Neither current target bridge implements these ports: the browser host protocol
has no window/channel operations, and the local CLI has no window host. The
types and module home are final enough for the presenter composition slice;
capability status is honest meanwhile.

## Export execution

The three effect records consume accepted export values:

- `DownloadPort` receives a `DeterministicArtifact`, or exact compressed bytes
  paired with their originating `ArchivePlan`;
- `PrintPort` receives `PrintPlan`;
- `ArchivePort` receives `ArchivePlan` and returns opaque non-empty
  `ArchiveBytes`.

`mkArchiveBytes` rejects an empty codec result before it can be delivered.
`PrintCompletion` distinguishes completed versus dismissed dialog. Neither
value asserts that a PDF file was acquired. Archive codecs must produce
deterministic bytes from the already sorted exact entries; a host cannot add
timestamps or platform paths.

Current native and browser bridges mark all three ports unavailable. The pure
HTML/LaTeX artifacts and PDF/archive capability plans remain real outputs of
`slideblaster-export`; this slice does not invent host completion.

## Compiler

`CompileRequest` carries:

- `CompileKind`: LaTeX fragment to HTML, TikZ picture to SVG, or LaTeX project
  to PDF;
- one exact `SourceBufferSnapshot`; and
- exact auxiliary `WorkspaceEntry` values.

Partially composed compiler hosts advertise support per `CompileKind`, so a
composition can disable only the unavailable compiler command before dispatch.
`compilerPort` also refuses an unavailable kind without target dispatch. The
result kind must match the request (`CompiledHtml`, `CompiledSvg`, or
`CompiledPdf`); a mismatch becomes a typed protocol error. Compiled TikZ
remains a view-only escape hatch and never enables canvas edits for unsupported
syntax.

No compiler interpreter is composed in this slice. Native local TeX and
packaged browser Wasm engines remain future target-specific implementations of
this contract.

## Clock and logging

`ClockPort` returns the presentation package's `TimerOrigin` from a monotonic
clock. It exposes no wall-clock date, timezone, or locale. Native uses
`getMonotonicTimeNSec` from `base`; the browser protocol does not yet expose a
monotonic clock.

`LogPort` carries a level, message, and scalar fields with validated ASCII
names. It deliberately has no bytes or arbitrary host-value constructor.
Callers must not put authored source, compiler input, credentials, or tokens in
text fields. Native writes a structured line to stderr. Browser logging uses
the existing typed `log.write` host call.

## Capability matrix after this slice

“Real” means the bridge invokes an existing implementation. “Partial” names
the exact admitted operation subset. “Unavailable” means the composition
returns `CapabilityUnavailable` before dispatch.

| Port / operation                                    | Native CLI bridge                                   | Browser Wasm bridge                                                 | Follow-up needed                                                  |
| --------------------------------------------------- | --------------------------------------------------- | ------------------------------------------------------------------- | ----------------------------------------------------------------- |
| workspace list                                      | real; recursive, sorted, `.git`/symlink excluded    | real; existing host text store                                      | browser working-copy filesystem replacing localStorage            |
| workspace read                                      | real exact bytes; arbitrary-byte support provided   | real UTF-8 bytes from host text; arbitrary-byte support unavailable | binary asset operation                                            |
| conditional replace                                 | real for existing file; documented best-effort race | unavailable                                                         | atomic versioned host compare/write                               |
| conditional create                                  | unavailable                                         | unavailable                                                         | exclusive/transactional create operation                          |
| Git version/status                                  | real                                                | unavailable                                                         | versioned browser Git host operation                              |
| Git init/stage/commit/log/branch/checkout/pull/push | operation unavailable                               | unavailable                                                         | full structured interpreters and shared-root laws                 |
| structured render measurement                       | unavailable                                         | unavailable; legacy plain-text call is insufficient                 | versioned structured content/resource protocol and native backend |
| presenter windows/channel                           | unavailable                                         | unavailable                                                         | versioned popup/channel host operations                           |
| download                                            | unavailable                                         | unavailable                                                         | artifact delivery operation                                       |
| print                                               | unavailable                                         | unavailable                                                         | execute `PrintPlan`, distinguish dispatch/acquisition             |
| archive                                             | unavailable                                         | unavailable                                                         | deterministic ZIP codec                                           |
| compiler                                            | unavailable                                         | unavailable                                                         | local TeX and packaged Wasm engines                               |
| monotonic clock                                     | real                                                | unavailable                                                         | browser monotonic clock operation                                 |
| structured log                                      | real                                                | real                                                                | no semantic follow-up                                             |

This table is the implementation claim. The existence of contracts for an
unavailable row is architecture coverage, not user-visible parity.

## Failure and stale-state behavior

- Invalid workspace paths fail before an adapter action.
- A storage conflict leaves bytes unchanged.
- An unsupported conditional mode performs no fallback write.
- Git unsupported operations never spawn a process or synthesize success.
- Host response/protocol errors stay distinct from capability absence.
- Measurement preserves the original ticket/key; batch completion rejects
  stale, duplicate, missing, or unexpected results.
- Presenter navigation sequence/session values allow Haskell to reject old or
  foreign channel messages.
- Export and compile completion must remain fenced by the app's source
  revision/job identity; a port result does not grant a current-document lease.
- Logging failures do not alter semantic state.

## Executable gates

The focused shared package suite must prove:

1. accepted workspace paths retain Unicode and segment spelling;
2. absolute, backslash, empty-segment, `.`, `..`, drive, control, NUL, and
   overlong paths are rejected;
3. `saveSourceSnapshot` sends exact expected/successor bytes;
4. a changed non-newer source snapshot reaches no write action;
5. every Git request maps to a closed `GitOperation`;
6. unsafe branch/remote names fail before an adapter;
7. response/request Git kinds are checked;
8. an adapter result helper preserves the authoritative measurement ticket/key;
9. an insufficient measurement host is represented as a typed failure; and
10. an empty archive codec result cannot claim success; and
11. unavailable whole ports are observable without invoking them.

Verification then expands to:

```text
native GHC package test with -Werror
  -> native adapter bridge build
  -> GHC Wasm shared-library build with -Werror
  -> web adapter bridge build
  -> host protocol fixtures for each promoted operation
  -> native/browser shared-workspace conformance
```

Browser runtime parity cannot be claimed until Wasm actually requests the
capability and a real browser acceptance test observes the result.
