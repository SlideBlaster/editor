# Development sessions

A durable session record has ID `SB2-YYYYMMDD-NNN` and lives at
`.META/sessions/<ID>/`. The date is its creation date and the sequence is the
next unused three-digit value for that date.

Every session requires:

| File | Purpose |
| --- | --- |
| `.prompt` | Exact initiating prompt supplied to the session-owning agent |
| `SESSION.md` | Identity, state, ownership, evidence, and handoff |
| `STEERING.md` | Material product-owner direction and accepted disposition |
| `REVIEW.md` | Demonstration, acceptance, change review, integration, and closure |

Type-specific files are:

| Type | Additional required files |
| --- | --- |
| `implementation` | `SPEC.md`, `SLICES.md` |
| `research` | `RESEARCH.md` |
| `maintenance` | `MAINTENANCE.md` |

Only implementation sessions use `SPEC.md` and `SLICES.md`. Their artifact,
observable functionality, demonstration, and product-owner acceptance are
specified once per `SPEC.md`, not once per slice.

Create a record from a clean `dev` tip with `scripts/session/create.sh`, passing
a reviewed prompt file or `-` for standard input. Review `.prompt` for secrets,
validate the record, and commit the entire session directory to `dev` before
creating its worktree. A normal worktree uses `session/<ID>` from that registered
`dev` point; its path may be outside the repository.

## States and gates

```text
active | blocked | ready-for-demonstration | changes-requested
  -> ready-for-review
  -> approved-for-integration
  -> integrated-awaiting-close
  -> closed
```

- `ready-for-review` requires product-owner observation, specification or
  outcome acceptance, and resolved steering.
- `approved-for-integration` additionally requires approval of an exact review
  unit.
- `integrated-awaiting-close` requires a full integration commit contained in
  `dev`.
- `closed` additionally requires an explicit product-owner closure request and
  approval.

Rejection and requested changes keep the session open. Automated tests,
independent review, integration, and release do not imply product-owner
acceptance or closure. `scripts/session/validate.sh` enforces the recorded
prerequisites for advanced states.

Completed work integrates only into `dev` and never advances `main`. Bulky
artifacts and worktree-local state remain ignored.
