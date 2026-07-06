# BrowserAuthAdapter

The web shell's real `AuthPort` (ADR 0010, M4). Replaces `DevAuthAdapter` for
signed-in GitHub sync. Pure transport: it speaks the HTTP contract below to the
Auth service and is blind to whether a real GitHub App or the local dev stub
answers — so identical code runs in Phase A (local stub) and Phase B (deployed).

## Contract

- Implements `AuthPort` from `@slideblaster/editor`.
- Constructed with `baseUrl` (Auth service, no trailing slash). `fetch`,
  `readCookie`, `navigate`, and `currentUrl` are injectable for tests/SSR.
- Use `createBrowserAuthAdapter(opts)`: it `restore()`s the session (`GET /me`)
  before returning, so `currentIdentity()` answers synchronously at first paint.
- `signIn` performs a full-page redirect to `/auth/github?return_to=<url>`; the
  page reloads on return and `restore()` re-seeds identity (the returned promise
  never resolves — navigation ends the page).
- `getRepoToken` `POST /mint`s a single-repo, `contents:write` (default),
  ≤1h token and caches it **in memory only**, keyed by `owner/name:scope`,
  reused until within 60s of expiry, then re-minted. Never persisted.
- `signOut` clears in-memory identity + token cache and best-effort `POST
/signout`s.
- `capabilities` reads `GET /capabilities`, falling back to the free tier.

## HTTP contract (Auth service)

All requests send `credentials: 'include'` (the session cookie is httpOnly +
Secure + SameSite). State-changing requests (`/mint`, `/signout`) carry a
double-submit CSRF token: the non-httpOnly `sb_csrf` cookie echoed in the
`x-sb-csrf` header.

| Method + path                     | Purpose                  | Response                                                                 |
| --------------------------------- | ------------------------ | ------------------------------------------------------------------------ |
| `GET /auth/github?return_to=`     | Start OAuth (redirect)   | 302 to GitHub, back to `return_to` with session cookie set               |
| `GET /me`                         | Current identity         | 200 `Identity` \| 401                                                    |
| `POST /mint` `{owner,name,scope}` | Mint a repo-scoped token | 200 `{value, expiresAt}` \| 401 (no session) \| 403 (no repo/App access) |
| `GET /capabilities`               | Capability flags         | 200 `CapabilityFlags` (401 → free tier)                                  |
| `POST /signout`                   | Drop the session         | 204                                                                      |

The minted `{value}` is secret — a GitHub App installation token. It is used
only as git HTTP basic-auth (`x-access-token:<value>`) and never logged.

## Deviations from DevAuthAdapter

Real server round-trips and OAuth redirect (vs instant local identity), an
httpOnly session cookie (vs localStorage), and short-lived minted tokens (vs an
injected PAT). None of this leaks past the `AuthPort` seam — callers (gitPanel,
sync UX) are unchanged.
