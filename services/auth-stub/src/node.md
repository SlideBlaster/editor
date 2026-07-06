# auth-stub node entry

Adapts `node:http` to the web-standard `Request`/`Response` that `createAuthStub`
speaks, so the stub runs under Node for local dev and in-process tests.

- `createAuthStubServer(options)` returns an `http.Server` funneling every request
  through one stub instance. Hop-by-hop request headers are dropped; the body is
  buffered. Handler errors become a 500.
- **Multiple `Set-Cookie`** (session + csrf) are emitted individually via
  `getSetCookie()` — the web `Headers.forEach` would otherwise comma-merge them
  into one invalid cookie.
- `listen(server, port)` starts it and resolves the bound port (`port = 0` picks a
  free one) — used by integration tests to stand up an in-process instance.
