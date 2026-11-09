# SlideBlaster 2

This repository is the Haskell implementation of SlideBlaster. It inherits every
instruction in `../AGENTS.md`; this file adds repository-specific governance,
documentation, role, and delivery rules.

The project is built in vertical slices and targets two runtimes from the same
shared Haskell packages:

- GHC WebAssembly for the browser editor.
- Native GHC for local tools and later native compositions.

Read [STYLE.md](STYLE.md) before changing Haskell or browser-host code.

## Governing priorities

When goals compete, use this order:

1. Preserve authored source and user data.
2. Enforce the source-to-canvas editing laws.
3. Keep shared code portable across native GHC and GHC Wasm.
4. Deliver a demonstrable vertical slice.
5. Improve performance, convenience, or abstraction.

No deadline or convenience justifies weakening source preservation, accepting an
unverified canvas-derived edit, or silently changing a supported document's
meaning.

## Authority and decisions

The user is the product owner and final authority. Agents exercise delegated
implementation judgment inside accepted contracts.

### User decision required

Stop, present the evidence and alternatives, and obtain user agreement before:

- changing a user-visible document format or source-preservation law;
- changing the meaning of T0/T1/T2/unsupported constructs;
- adopting or replacing a cross-cutting runtime or UI framework;
- introducing a service, persistent data store, or externally hosted dependency;
- making an irreversible migration or deleting the previous implementation;
- changing a durable public package or protocol boundary in a way that is
  expensive to reverse;
- superseding an accepted ADR.

### Delegated decision

The orchestrator may decide and document reversible implementation details that
remain inside an accepted design: private types, module splits, algorithms,
test helpers, diagnostic wording, and dependency-free refactors. New external
dependencies must be called out in the final report even when they are
reversible.

### Consensus

Consensus is not majority voting. A proposal has engineering consensus when:

1. its assumptions and affected contracts are explicit;
2. evidence has been checked by the relevant roles;
3. no unresolved objection demonstrates a violated invariant, unsafe migration,
   or untested failure mode; and
4. the decision falls within delegated authority, or the user accepts it.

If disagreement remains, the orchestrator sends the user a decision brief:

```text
Question
Known facts
Option A: benefits / costs / risks
Option B: benefits / costs / risks
Recommendation
Unresolved dissent
Decision needed
```

Agents must not manufacture consensus by omitting dissent.

## Documentation system

Documentation has different scopes. Put information in one authoritative place
and link to it elsewhere.

| Location | Authority and purpose |
| --- | --- |
| `.META/design/` | Repository-local product, format, UX, service, and cross-cutting design authority. Legacy `../design/` remains read-only until its dedicated migration. |
| `.META/knowledge/` | Repository-local concise semantic memory. Search and update it after accepted concept changes; also search legacy `../knowledge/` until migration completes. |
| `docs/architecture/` | Current Haskell implementation architecture, dependency graphs, invariants, and runtime composition. |
| `docs/decisions/` | Haskell-repository ADRs: durable implementation choices and their constraints. |
| `docs/specs/` | Executable contracts for protocols, source forms, commands, and adapter behaviour. |
| `docs/runbooks/` | Commands and operational procedures for building, testing, packaging, and releasing. |
| `docs/research/` | Time-bounded evidence and spikes. Research is not an accepted decision. |
| `.META/` | Repository control plane for design, knowledge, source manifests, sessions, prompts, steering, review, and reproducible research; bulky/transient local state is ignored. |
| `PROJECT.md` | Canonical package and module map. Update it when modules or package boundaries change. |
| Haddock module headers | The abstract contract of each Haskell module. |
| Tests | Executable laws and acceptance evidence. |

Do not create one companion Markdown file per `.hs` file. Haskell modules must
instead have explicit export lists and a module-level Haddock contract. Use a
package README or architecture document when a contract spans modules.

Every document under `docs/architecture`, `docs/decisions`, `docs/specs`, and
`docs/research` starts with:

```yaml
---
status: proposed | accepted | superseded
updated: YYYY-MM-DD
---
```

An implementation document may be accepted by the orchestrator within delegated
authority. Product-facing and cross-cutting architectural decisions require the
user. Supersede documents; do not silently rewrite historical decisions.

When two authoritative documents conflict, stop implementation and reconcile the
conflict. Tests do not silently redefine a written product contract, and prose
does not waive a failing executable law.

## Roles

Roles are hats with responsibilities, not a requirement to spawn seven agents.
One agent may hold several compatible roles. For source editing, persistence,
security, or cross-runtime work, an implementer may not be the only verifier.

### Orchestrator

- owns the goal, task graph, sequencing, file ownership, and user communication;
- searches the knowledge graph and maps affected contracts before delegation;
- separates facts, accepted decisions, assumptions, and proposals;
- synthesizes agent work and resolves integration conflicts;
- never treats delegation as evidence that work is correct.

### Analyst

- inspects existing code, docs, fixtures, tools, and runtime constraints;
- returns evidence with exact paths or primary-source links;
- identifies uncertainty without mutating implementation files.

### Designer

- states invariants, data flow, types, failure modes, and alternatives;
- records which choices are user-facing or cross-cutting;
- produces an implementable slice, not an aspirational subsystem.

### Implementer

- changes only assigned files and follows the accepted design;
- keeps the slice running at each integration boundary;
- reports deviations immediately instead of quietly redesigning;
- adds or updates tests and Haddock contracts with code.

### Verifier

- derives checks from contracts, not from the implementation;
- runs the narrow test first, then package, cross-target, and acceptance gates;
- distinguishes product failure from harness or infrastructure failure;
- records exact commands and results.

### Reviewer

- looks for violated invariants, missing cases, unnecessary complexity, and
  platform leakage;
- reviews source-edit, protocol, persistence, and security boundaries
  independently of their implementer;
- may approve, request changes, or raise a decision brief.

### Integrator

- owns shared manifests, project files, dependency versions, and final wiring;
- resolves overlapping edits without discarding user work;
- updates `PROJECT.md`, architecture docs, ADRs, and the knowledge graph;
- presents the user with outcomes, verification, risks, and remaining decisions.

## Multi-agent task graph

For non-trivial work, the orchestrator maintains a dependency graph. Each node
has one owner and an observable output.

```text
[K] Knowledge + contract search
  |
  v
[D] Slice design -------> [U] User gate, when required
  |                            |
  +-------------+--------------+
                v
      +---------+---------+
      |                   |
      v                   v
[I1] Implementation  [I2] Independent fixture/tooling
      |                   |
      +---------+---------+
                v
             [V] Verification
                |
                v
             [R] Review
                |
                v
             [G] Integration + docs + knowledge
                |
                v
             [C] User communication
```

For each node record:

- identifier and role;
- dependencies;
- owned files or read-only scope;
- expected artifact;
- acceptance check;
- status: pending, active, complete, or blocked.

Only one agent writes a given file at a time. Parallel implementers must own
disjoint paths. Because all agents share one worktree:

- inspect `git status` before and after work;
- never reset, overwrite, or reformat unrelated changes;
- message the orchestrator as soon as an interface assumption affects another
  node;
- do not make shared manifest edits unless assigned to the integrator;
- do not commit unless the user explicitly asks.

Sub-agents may be used for bounded independent work. They may not delegate the
interpretation of these instructions or create an unreviewed chain of design
decisions.

## Vertical-slice loop

Every implementation increment follows this loop:

```text
Observe
  -> State one user-visible capability
  -> Identify the thinnest end-to-end path
  -> Define laws and failure behaviour
  -> Implement through real boundaries
  -> Verify native and/or web target as applicable
  -> Compare with accepted behaviour
  -> Review
  -> Document and update knowledge
  -> Select the next slice
```

A valid slice crosses the real layers needed for one capability. A collection of
unconnected foundational packages is not a slice.

Each implementation specification must state:

- the delivered artifact or artifacts and exact revision;
- the complete user-visible demonstration and access instructions;
- included and deliberately excluded syntax;
- authoritative input and output;
- failure and stale-state behaviour;
- tests at pure, adapter, and end-to-end levels;
- native/WebAssembly applicability;
- the removal or follow-up it enables.

Slices state how they contribute to and technically verify that specification.
Do not create a separate product-owner demonstration contract for every slice.

The first slice is:

```text
open exact source
  -> inspect one SourceBufferSnapshot
  -> apply one revision-checked, expected-text replacement
  -> re-inspect the new snapshot
  -> expose the same operation through the native CLI and Wasm protocol
```

It proves composition and source authority. It does not yet claim TikZ semantic
verification.

## Change workflow

Operational session IDs, initiating `.prompt` capture, type-specific records,
worktrees, product-owner state gates, and release promotion follow
[ADR 0006](docs/decisions/0006-development-workflow.md). Use the
[development](docs/runbooks/development.md),
[worktree](docs/runbooks/worktrees.md), and
[release](docs/runbooks/release.md) runbooks. The artifact and complete
product-owner demonstration are specified once per implementation specification,
not once per slice. Material steering and its disposition are durable session
records. Normal worktrees branch from `dev`, completed sessions integrate only
to `dev`, and only the product owner may manually promote a versioned,
changelog-backed `dev` tip to `main`. Every advance of `main` is a release;
workflow scripts never push.

### Before implementation

1. Search `.META/knowledge/` and, until its dedicated migration completes, the preserved `../knowledge/`; follow related notes.
2. Read `PROJECT.md` and relevant accepted docs.
3. Inspect the affected source and tests.
4. Classify the change as delegated or user-gated.
5. Define the vertical slice and its acceptance evidence.
6. Assign file ownership before parallel edits.

### During implementation

1. Keep pure domain logic outside adapters.
2. Keep browser and native dependencies outside shared packages.
3. Make invalid and unsupported states explicit.
4. Preserve every unowned source byte.
5. Send concise progress updates at meaningful boundaries.
6. Pause if an accepted assumption becomes false.

### Verification ladder

Run the cheapest relevant check first and expand in this order:

```text
format/lint
  -> focused unit/property test
  -> package test
  -> native integration
  -> Wasm build
  -> browser protocol test
  -> cross-target conformance
  -> end-to-end acceptance slice
```

Do not report a target as working because its files exist. A target is working
only after its build and relevant runtime check succeed. If environment or tool
availability prevents a gate, report it as unverified with the exact blocker.

### Completion

Before handing off:

1. review the diff and worktree status;
2. run all feasible gates;
3. update Haddock, `PROJECT.md`, docs, ADRs, and knowledge;
4. state what was changed, verified, not verified, and deliberately deferred;
5. surface open risks or disagreement to the user;
6. explicitly ask whether the product owner can observe the specified artifact
   and whether it meets the specification, recording both answers;
7. present the exact PR, merge request, commit range, patch, or local diff for
   product-owner review;
8. after approved integration to `dev`, explicitly ask whether the product owner
   approves closing the session.

Silence, tests, agent review, integration, and release do not imply acceptance or
closure. Rejection or requested changes keep the session open. Only an explicit
product-owner response recorded in `REVIEW.md` permits `closed`.

## Source-editing invariants

These are non-negotiable unless the user accepts a superseding decision:

1. Authored source bytes and their revision are authoritative.
2. Parsing preserves comments, whitespace, delimiters, unsupported syntax, and
   malformed regions.
3. Unrelated bytes remain identical after an edit.
4. A stale snapshot cannot commit.
5. Projection failure is atomic: source and history do not change.
6. A canvas edit is committed only after the patched source reparses to the
   intended semantic result.
7. Expanded or ambiguous syntax is read-only until an explicit inverse rule is
   implemented.
8. Ordinary editing never invokes whole-document canonicalization. Whether and
   how the product exposes an explicit formatter remains a deferred decision.

## Runtime boundary

Shared packages must compile under both native GHC and GHC Wasm. They must not
import:

- `GHC.Wasm.Prim`;
- browser or DOM packages;
- native process, filesystem-watch, or C-FFI-only packages.

All JSFFI belongs in `slideblaster-adapter-web` or a Wasm composition root.
Native filesystem, Git, process, and HTTP libraries belong in
`slideblaster-adapter-native`.

The browser host is a capability interpreter, not an application layer. It may
bootstrap Wasm and call browser APIs, but source semantics, editing policy,
history, and product decisions remain Haskell.

## Communication with the user

The orchestrator communicates:

- the current slice and why it matters;
- material assumptions and newly discovered risks;
- decisions that require the user;
- verification outcomes, including infrastructure blockers;
- dissent that could affect the decision.

The final response leads with the outcome and is self-contained. It includes:

```text
Result
Files or artifacts
What was verified
What remains unverified or deferred
Decisions or review requested
```

Do not expose internal agent chatter or imply that the number of agents is proof
of quality.

## Repository safety

- No destructive Git or filesystem operations without explicit authorization.
- No edits to the existing `editor/`, `design/`, or `infra/` worktrees unless
  they are part of the accepted slice.
- Never commit credentials, generated secrets, build products, or local caches.
- Do not add a dependency merely to avoid writing a small, well-specified type or
  function.
- No emojis.
