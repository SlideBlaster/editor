# Auth port

Identity plus the short-lived, repo-scoped tokens the client uses to talk to the
user's GitHub repo. The security-critical seam (ADR 0010, `design/architecture/auth.md`).

## Contract

- `signIn` / `signOut` / `currentIdentity` manage the session. The session secret
  lives in an http-only cookie (web) or the OS keychain (desktop); it is never
  exposed through this interface.
- `getRepoToken` returns a `ScopedToken` scoped to a single repo, `contents`-only,
  and short-lived (<= 1h). It is minted by the isolated Auth service (GitHub App,
  KMS-held key). Adapters may cache an unexpired token in memory but must never
  persist it. Callers treat `expiresAt` as hard.
- `capabilities` returns server-authoritative flags (premium collab, managed
  storage, seat caps). Flags are advisory hints for the UI; the server re-checks
  them at every privileged boundary (token mint, collab join).

## Adapters

Browser: talks to the Auth service; session in a cookie. Native: same, plus the OS
keychain for the session secret. No managed variant. See ADR 0010.
