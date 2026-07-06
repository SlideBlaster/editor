/**
 * Cloudflare Worker entry for the Auth service. Contract: worker.md.
 *
 * Thin adapter: wire config + KV sessions + the GitHub client (real key via the
 * MintingKey seam) into the runtime-agnostic handler. All behavior lives there.
 */
import { configFromEnv, type Env } from './config'
import { createGitHubClient } from './github'
import { createAuthHandler } from './handler'
import { createLocalMintingKey } from './mintingKey'
import { createKvSessionStore } from './sessions'

export default {
  fetch(request: Request, env: Env): Promise<Response> {
    const config = configFromEnv(env)
    const mintingKey = createLocalMintingKey(config.appPrivateKey)
    const github = createGitHubClient(config, mintingKey, fetch)
    const sessions = createKvSessionStore(env.SB_SESSIONS)
    return createAuthHandler({ config, sessions, github }).handle(request)
  },
}
