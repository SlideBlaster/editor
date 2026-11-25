# Operational research

Store each operational research run in a directory named:

```text
<session-id>--<task-slug>--<agent-slug>--<run>
```

For example:

```text
SB2-20260726-003--wasm-link-time--kiro-verifier--01
```

The task and agent slugs use lowercase ASCII letters, digits, and hyphens. The
two-digit run distinguishes repeated measurements. Create a run with
`scripts/research/create.sh`; every directory contains a tracked `README.md`
recording the question, provenance, commands, environment, observations,
limitations, and conclusion.

Research is evidence, not a decision. Promote durable conclusions to the
appropriate spec, ADR, architecture document, test, or shared knowledge note
and mark the report promoted or superseded.

Bulky captures, generated corpora, screenshots, traces, binaries, and tool
caches belong in the run's `artifacts/` directory and are ignored. Never store
credentials or private user documents. Record enough source, version, command,
date, checksum, and conclusion in the tracked report for another person to
reproduce or audit the result.
