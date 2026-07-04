# SlideBlaster

> **[PROJECT.md](./PROJECT.md)** — the canonical module map of this codebase. Read it to orient yourself, and keep it up to date whenever modules change.

# Workflow

Discuss the design before writing code. For any non-trivial change:

1. Think the implementation through fully before proposing it: the files and modules involved (orient with PROJECT.md), the approach, data flow, edge cases, failure modes, and how it fits the existing architecture.
2. Present a design and implementation plan, including alternatives and tradeoffs, and call out any open questions or assumptions.
3. Wait for my agreement on the approach before making any edits.
4. Only implement once we have settled on the design. If the plan needs to change mid-implementation, pause and discuss before continuing.

Keep plans concrete and specific to this codebase, not generic. Small, obviously safe fixes (typos, formatting) do not need a full design discussion.

# Code Database

Every code file must have a corresponding `.md` file that describes the abstract contract of that module. For example, `src/parser.ts` must have a `src/parser.md`.

Each `.md` file describes what the module does and the contract it exposes: its responsibility, the interface it provides (inputs, outputs, key types), invariants and assumptions it relies on, and how it relates to the rest of the system. Keep it abstract — describe the contract, not the implementation details.

Do not keep a changelog or rationale log here; history and the reasons behind changes live in git.

When creating or modifying a code file, keep its companion `.md` file in sync so the contract always reflects the current behavior.

# Style

- No Emojis
