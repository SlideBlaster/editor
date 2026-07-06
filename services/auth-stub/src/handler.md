# auth-stub handler

Runtime-agnostic core of the local Auth-service double. `createAuthStub(options)`
returns `{ handle(request) }` closing over an in-memory session store (one per
instance, so dev servers and tests don't share state).

## Routes (the Auth-service HTTP contract)

| Route                             | Behavior                                                                                                                                                                                           |
| --------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GET /auth/github?return_to=`     | Create a session (opaque id + csrf), set `sb_session` (HttpOnly) + `sb_csrf` (readable) cookies, 302 to a **path-only** `return_to` (absolute URLs are stripped to their path — no open redirect). |
| `GET /me`                         | Session → `Identity`; none → 401.                                                                                                                                                                  |
| `POST /mint` `{owner,name,scope}` | Requires session (else 401) and `x-sb-csrf` matching the session csrf (else 403). Returns `{value, expiresAt}`.                                                                                    |
| `GET /capabilities`               | Session → `CapabilityFlags`; none → 401.                                                                                                                                                           |
| `POST /signout`                   | Delete the session; expire both cookies (Max-Age=0); 204.                                                                                                                                          |
| `OPTIONS *`                       | Credentialed CORS preflight (echoes Origin, allows credentials).                                                                                                                                   |

## Options

- `identity` — the dev user (default `dev`).
- `mintToken` — token `/mint` returns; default a synthetic `dev-token:<owner>/<name>`.
  Set a real repo PAT for the real-GitHub path.
- `tokenTtlMs` — minted-token lifetime (default 1h, the ADR ceiling).
- `capabilities` — flags for `/capabilities` (default free tier).
- `secureCookies` — emit `Secure` (off for http://localhost dev).

## Deviations from the real service (accepted, dev-only)

No GitHub OAuth (identity is asserted), no per-repo App-installation
authorization (mint grants all), no KMS-signed token, sessions in memory only.
All confined to this service; the client sees only the contract.
