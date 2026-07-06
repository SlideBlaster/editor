/**
 * Builds + signs the short-lived GitHub App JWT (RS256). Contract: appJwt.md.
 *
 * `iss` = the App's client id (GitHub's current recommendation; the App id also
 * works), `iat` backdated 30s for skew, `exp` at +9min (GitHub's ceiling is 10min).
 * Signed through the `MintingKey` seam, so this module never touches key material.
 */
import type { AuthConfig } from './config'
import { base64urlFromBytes, base64urlFromString } from './encoding'
import type { MintingKey } from './mintingKey'

export async function generateAppJwt(config: AuthConfig, mintingKey: MintingKey): Promise<string> {
  const iss = config.githubClientId || config.githubAppId
  if (!iss) throw new Error('GitHub App identity (client id / app id) is not configured')

  const now = Math.floor(Date.now() / 1000)
  const header = base64urlFromString(JSON.stringify({ alg: 'RS256', typ: 'JWT' }))
  const claims = base64urlFromString(JSON.stringify({ iss, iat: now - 30, exp: now + 540 }))
  const signingInput = `${header}.${claims}`
  const signature = await mintingKey.sign(signingInput)
  return `${signingInput}.${base64urlFromBytes(signature)}`
}
