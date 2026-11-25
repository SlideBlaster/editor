# {{SESSION_ID}} product-owner review and closure

These machine-readable fields gate session states. Do not replace `pending`
without recording the actual request and product-owner response. Observation and
specification or outcome acceptance are separate decisions.

- Artifact revision: `pending`
- Demonstration requested: `pending`
- Observation question: `pending`
- Observation response: `pending`
- User observed artifact: `pending`
- Acceptance question: `pending`
- Acceptance response: `pending`
- Specification or outcome accepted: `pending`
- Steering resolved: `pending`
- Review unit: `pending`
- Change review request: `pending`
- Change review response: `pending`
- Product-owner review: `pending`
- Integrated to dev: `pending`
- Integration commit: `pending`
- Closure requested: `pending`
- Closure question: `pending`
- Closure response: `pending`
- Product-owner closure: `pending`

## Demonstration record

Quote or link the complete exchange and provide exact access instructions,
starting state, actions, expected observations, limitations, and demonstrated
revision. The top-level question and response fields are single-line durable
summaries; preserve important nuance here.

## Steering disposition

List every material `STR-NNN` entry and its accepted disposition. The validator
rejects advanced states while `STEERING.md` contains a pending disposition.

## Change review

`Review unit` must identify an exact `pr:`, `mr:`, `commits:`, `patch:`, `diff:`,
or `local-diff:` target. Quote or link the review exchange here. Requested
changes or rejection must be reflected by an open session state, never approved
or closed.

## Integration evidence

Record the `dev` integration command or method, full commit, and post-integration
checks. Integration does not itself close the session.

## Closure record

Quote the explicit question naming the session and the product-owner response.
Only the product owner can approve closure. Rejection or requested changes keep
the session open.
