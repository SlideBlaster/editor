# DevAuthAdapter

A development stand-in for the Auth port, so the app codes against the real
`AuthPort` seam (identity for commit authorship, tokens for remote git) before
the Auth service ships (ADR 0010, M4). Swapping in the real browser adapter
later requires no app changes.

## Contract

- Implements `AuthPort` from `@slideblaster/editor`.
- `signIn` succeeds instantly with a configured local identity (default login
  `dev`); the identity persists in localStorage so reloads stay signed in
  (in-memory fallback outside the browser). `signOut` clears it.
- `getRepoToken` wraps an optionally injected PAT as a `ScopedToken` (1h expiry)
  for manual remote testing; without one it rejects with a message pointing at
  M4. The PAT is injected at construction (e.g. from a Vite env var), never
  persisted by the adapter.
- `capabilities` reports the free tier (no premium collab, no managed storage,
  zero seats).

## Deviations from the real adapter (accepted, dev-only)

No real session cookie, no server round-trip, identity is client-asserted, and
the "token" is a long-lived PAT rather than a minted short-lived credential.
None of this leaks into the app: callers see only the port.
