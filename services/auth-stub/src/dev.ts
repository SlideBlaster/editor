/**
 * Local dev launcher for the auth stub. Contract: see dev.md.
 *
 * `pnpm --filter @slideblaster/auth-stub dev` starts it on SB_AUTH_STUB_PORT
 * (default 8788). The web-shell's Vite dev server proxies /auth, /me, /mint,
 * /capabilities, /signout here so the browser talks to it same-origin (no CORS,
 * first-party cookies). Set SB_AUTH_STUB_PAT to a fine-grained repo PAT to mint
 * a token that reaches a real GitHub repo through the git-proxy.
 */
import { createAuthStubServer, listen } from './node.ts'

const port = Number(process.env.SB_AUTH_STUB_PORT ?? 8788)
const server = createAuthStubServer({ mintToken: process.env.SB_AUTH_STUB_PAT })

void listen(server, port).then((bound) => {
  // eslint-disable-next-line no-console
  console.log(`auth-stub listening on http://localhost:${bound}`)
})
