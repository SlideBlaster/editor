# service: auth

The isolated Auth service (Phoenix). Holds the GitHub App identity, mints
short-lived repo-scoped tokens with a KMS/HSM-held key, manages sessions and
capability flags. The security-critical seam.

Not a pnpm package (Elixir). Design: `design/architecture/auth.md`, ADR 0010.
Stood up at M4.
