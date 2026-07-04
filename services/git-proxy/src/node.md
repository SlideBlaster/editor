# git-proxy node entry

Adapts `node:http` to the web-standard `Request`/`Response` that `handleProxy`
speaks, so the proxy runs under Node for local dev and tests.

- `createProxyServer(options)` returns an `http.Server` that funnels every request
  through `handleProxy`. Hop-by-hop request headers are dropped; the body is
  buffered (fine at spike scale). Handler errors become a 502.
- `listen(server, port)` starts it and resolves the bound port (`port = 0` picks a
  free one) — used by the integration test to stand up an in-process proxy.

Not the production runtime (that is `worker.ts` on Cloudflare); this entry keeps the
core exercisable without deploying.
