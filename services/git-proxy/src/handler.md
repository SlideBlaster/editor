# git-proxy handler

The runtime-agnostic core of the first-party CORS proxy. One function,
`handleProxy(request) -> response`, built on web-standard `Request`/`Response`/
`fetch` so the same code runs on a Cloudflare Worker (`worker.ts`) and under Node
(`node.ts`).

## Why it exists

Browser isomorphic-git cannot reach GitHub's git-smart-http endpoints directly:
they are not CORS-enabled. The client points its `corsProxy` at this service, which
forwards the request server-to-server and returns it with CORS headers. A
short-lived, repo-scoped `contents` token rides the `Authorization` header through
here, so the proxy is deliberately minimal and non-logging (`design/architecture/auth.md`).

## Contract

- **Path encoding:** isomorphic-git requests `${corsProxy}/{host}/{owner}/{repo}/...`
  (remote URL minus protocol). `resolveTarget` reconstructs `https://{host}/...` and
  preserves the query string.
- **Allowlist (hard):** upstream must be `https`, host exactly the allowed host
  (`github.com` by default), and path exactly one of `info/refs`,
  `git-upload-pack`, `git-receive-pack`. Anything else -> 403. Only `GET`, `POST`,
  `OPTIONS`; else 405.
- **Header hygiene:** only a curated request-header set is forwarded (including
  `authorization`, never logged); only a curated response-header set is returned.
- **CORS:** `OPTIONS` gets a preflight (allow methods/headers, 10-min max-age);
  responses carry `access-control-allow-origin` (echoing the request origin) and
  `access-control-expose-headers`.
- **No logging, no persistence, no auth of its own.** It is a dumb, locked-down
  forwarder; authorization is GitHub's job via the transiting token.

## Entries

`node.ts` (http server, local/dev/test) and `worker.ts` (Cloudflare Worker) both
delegate here. Runtime target: Cloudflare Worker (ADR 0013 / roadmap Track 0).
