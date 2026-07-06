/**
 * Auth Worker configuration + the wire-contract types. Contract: config.md.
 *
 * `AuthConfig` is the runtime-agnostic settings the core consumes; `Env` is the
 * Cloudflare binding shape. `Identity` / `CapabilityFlags` mirror the `AuthPort`
 * contract in `@slideblaster/editor` — kept as local literals so the Worker has no
 * heavy dependency; the adapter↔service test guards against drift.
 */

/** Identity JSON returned by `/me` (mirrors `@slideblaster/editor` `Identity`). */
export interface Identity {
  login: string
  id: string
  avatarUrl?: string
}

/** Flags returned by `/capabilities` (mirrors `CapabilityFlags`). */
export interface CapabilityFlags {
  premiumCollab: boolean
  managedStorage: boolean
  collaboratorSeats: number
}

export type SameSite = 'Lax' | 'None' | 'Strict'

export interface AuthConfig {
  githubAppId: string
  githubClientId: string
  githubClientSecret: string
  /** The App private key PEM (PKCS#1 or PKCS#8). Later: a KMS-access credential. */
  appPrivateKey: string
  /** Web-shell origin — cookie/redirect allowlist + CORS. */
  webShellOrigin: string
  secureCookies: boolean
  sameSite: SameSite
}

/** Minimal Workers KV surface (avoids a @cloudflare/workers-types dependency). */
export interface KVNamespace {
  get(key: string, type: 'json'): Promise<unknown>
  put(key: string, value: string, options?: { expirationTtl?: number }): Promise<void>
  delete(key: string): Promise<void>
}

/** Cloudflare Worker bindings (wrangler.toml `[vars]` + KV + secrets). */
export interface Env {
  SB_SESSIONS: KVNamespace
  GITHUB_APP_ID: string
  GITHUB_CLIENT_ID: string
  GITHUB_CLIENT_SECRET: string
  APP_PRIVATE_KEY: string
  WEB_SHELL_ORIGIN: string
  SECURE_COOKIES?: string
  COOKIE_SAMESITE?: string
}

export function configFromEnv(env: Env): AuthConfig {
  const sameSite = (env.COOKIE_SAMESITE ?? 'Lax') as SameSite
  return {
    githubAppId: env.GITHUB_APP_ID,
    githubClientId: env.GITHUB_CLIENT_ID,
    githubClientSecret: env.GITHUB_CLIENT_SECRET,
    appPrivateKey: env.APP_PRIVATE_KEY,
    webShellOrigin: env.WEB_SHELL_ORIGIN || 'http://localhost:5173',
    secureCookies: env.SECURE_COOKIES === 'true',
    sameSite,
  }
}
