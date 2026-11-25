# SB2-20260726-001 steering log

## STR-001

- Received: `2026-07-27`
- Source: `conversation`
- Affects: `.META` authority, specification evidence, user acceptance, review, closure
- Disposition: `applied`

### User direction

Move product design and semantic knowledge under `.META`. Always record the
artifact and functionality or fix visible to the user, explicitly ask whether
the user sees it, account for steering, require review of the PR, merge, or
other exact change unit, and keep a rejected session open.

### Interpretation and effect

`.META/design/` and `.META/knowledge/` become destination authorities. Sessions
receive durable steering and review records plus product-owner-gated states.

## STR-002

- Received: `2026-07-27`
- Source: `conversation`
- Affects: prompt provenance, specification boundary, legacy migration
- Disposition: `applied`

### User direction

> yes eventually we will launch one agent .fr this. lets maybe sure any session own agents also writes its intial promopt to .prompt in the session dir okay yes revise 1 yes 2 yes 3 no not per slice this shoudl be per spec 5 yes lets add the state macgine agreed with the rest

### Interpretation and effect

- Legacy `design/` and `knowledge/` migration is deferred to one dedicated agent
  and no legacy content is moved or deleted in this session.
- Every new session captures its initiating prompt in `.prompt`.
- Artifact, observable behaviour, demonstration, and acceptance are per
  implementation specification, not per slice.
- The explicit product-owner state machine and closure safeguards are accepted.
