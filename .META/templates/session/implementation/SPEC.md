# {{SESSION_ID}} specification

## User-visible capability

State the observable capability or fix governed by this specification.

## Contracts and invariants

List authoritative inputs, outputs, preservation laws, and affected boundaries.

## Included and excluded scope

Name supported syntax or behaviour and deliberate exclusions.

## Failure and stale-state behaviour

State atomicity, diagnostics, and revision handling.

## Delivery artifacts

For each artifact record its kind, tracked location or exact access command,
revision, purpose, and whether it is runnable, inspectable, or evidence-only.
Screenshots and transcripts may support but do not replace runnable behaviour
when interactive functionality is claimed.

## Product-owner demonstration

Record one demonstration for this specification, not one per implementation
slice:

- starting state and prerequisites;
- exact launch command, URL, file, or executable;
- actions the product owner performs;
- visible or otherwise observable result after each action;
- known limitations, mocks, and unavailable targets;
- the exact revision being demonstrated.

The agent must explicitly ask whether the product owner can observe the result
and separately whether it satisfies the intended product behaviour. Record the
answers in `REVIEW.md`; silence is not acceptance.

## Acceptance evidence

List pure, adapter, end-to-end, native, and Wasm checks that apply. Automated
checks establish technical evidence but cannot replace product-owner
observation, acceptance, change review, or closure.
