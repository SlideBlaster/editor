# SB2-20260726-001 slices

## Dependency graph

```text
S1 Preserve current work and establish dev
  -> S2 Install metadata and typed session templates
      -> S3 Add worktree and research helpers
          -> S4 Add version/changelog and manual release checks
              -> S5 Validate and independently review the initial scaffold
                  -> S6 Add prompt, steering, per-spec demo, review, and closure gates
```

## Slice status

### S1-S5

Technically complete. Their combined initial workflow artifact was independently
reviewed before product-owner steering added S6. They do not independently
constitute product-owner acceptance or session closure.

### S6

- Capability contribution: capture initiating prompts and require explicit
  product-owner observation, specification acceptance, exact change review,
  integration evidence, and closure.
- Specification artifact produced or changed: `SPEC.md`, common session records,
  state validation, `.META` design/knowledge destinations, ADR and runbooks.
- Authoritative input/output: product-owner steering to tracked repository
  control-plane and workflow records.
- Real boundaries crossed: templates, Bash validation, Git ancestry, docs, and
  isolated fixture repositories.
- Failure behaviour: advanced or closed states fail validation when any required
  product-owner or integration evidence is absent.
- Native/WebAssembly applicability: host-side workflow only; no product target
  behavior changes.
- Technical verification: repository-local checks and isolated state fixtures.
- Follow-up enabled: one dedicated future migration session for legacy design
  and knowledge.

## Verification ladder

1. Bash syntax and metadata validation.
2. Prompt-preserving typed session creation.
3. State-machine rejection and accepted-closure fixtures.
4. Worktree, research, and release fixtures.
5. Documentation, diff, and independent review.
6. Single specification-level product-owner demonstration and change review.
