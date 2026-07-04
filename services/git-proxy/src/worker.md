# git-proxy worker entry

The Cloudflare Worker entry: a thin `fetch` adapter delegating to `handleProxy`.
This is the production runtime target for the proxy (ADR 0013 / roadmap Track 0):
edge-deployed, no disk, trivially non-logging, minimal surface — the security
posture the transiting token requires (`design/architecture/auth.md`).

Deployed via `wrangler.toml`. All behavior is in `handler.ts`; keep this file
adapter-only.
