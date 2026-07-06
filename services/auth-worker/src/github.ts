/**
 * GitHub REST client for the auth flow. Contract: github.md.
 *
 * OAuth code exchange, identity, the authorize-then-mint path (single-repo token),
 * and the App install URL. Every mint is authorized against the *user's own*
 * installations (no confused deputy): we only mint for a repo the signed-in user
 * can reach through an installation of our App.
 */
import type { AuthConfig, Identity } from './config'
import { generateAppJwt } from './appJwt'
import type { MintingKey } from './mintingKey'

const API = 'https://api.github.com'
const OAUTH = 'https://github.com/login/oauth/access_token'

export type MintResult =
  { ok: true; value: string; expiresAt: number } | { ok: false; reason: 'no_repo_access' | 'error' }

export interface GitHubClient {
  exchangeCode(code: string): Promise<string | null>
  getUser(userToken: string): Promise<Identity | null>
  mintRepoToken(userToken: string, owner: string, name: string): Promise<MintResult>
  installUrl(): Promise<string | null>
}

export function createGitHubClient(
  config: AuthConfig,
  mintingKey: MintingKey,
  fetchImpl: typeof fetch = fetch,
): GitHubClient {
  const appHeaders = async (): Promise<HeadersInit> => ({
    authorization: `Bearer ${await generateAppJwt(config, mintingKey)}`,
    ...baseHeaders,
  })
  const userHeaders = (token: string): HeadersInit => ({
    authorization: `Bearer ${token}`,
    ...baseHeaders,
  })

  const exchangeCode: GitHubClient['exchangeCode'] = async (code) => {
    const res = await fetchImpl(OAUTH, {
      method: 'POST',
      headers: { accept: 'application/json', 'content-type': 'application/json' },
      body: JSON.stringify({
        client_id: config.githubClientId,
        client_secret: config.githubClientSecret,
        code,
      }),
    })
    if (!res.ok) return null
    const body = (await res.json()) as { access_token?: string }
    return body.access_token ?? null
  }

  const getUser: GitHubClient['getUser'] = async (userToken) => {
    const res = await fetchImpl(`${API}/user`, { headers: userHeaders(userToken) })
    if (!res.ok) return null
    const b = (await res.json()) as { login: string; id: number; avatar_url?: string }
    return { login: b.login, id: String(b.id), avatarUrl: b.avatar_url }
  }

  // The App installation that covers owner/name (authenticated AS the App).
  const installationForRepo = async (owner: string, name: string): Promise<number | 'none'> => {
    const res = await fetchImpl(`${API}/repos/${owner}/${name}/installation`, {
      headers: await appHeaders(),
    })
    if (res.status === 404) return 'none'
    if (!res.ok) return 'none'
    const b = (await res.json()) as { id: number }
    return b.id
  }

  // Confirm THIS user can reach owner/name through that installation; return repo id.
  const authorizeUserRepo = async (
    userToken: string,
    installationId: number,
    owner: string,
    name: string,
  ): Promise<number | null> => {
    const full = `${owner}/${name}`.toLowerCase()
    const res = await fetchImpl(
      `${API}/user/installations/${installationId}/repositories?per_page=100`,
      { headers: userHeaders(userToken) },
    )
    if (!res.ok) return null
    const b = (await res.json()) as { repositories: { id: number; full_name: string }[] }
    const repo = b.repositories.find((r) => (r.full_name ?? '').toLowerCase() === full)
    return repo ? repo.id : null
  }

  // Mint the scoped installation token (authenticated AS the App).
  const installationToken = async (
    installationId: number,
    repoId: number,
  ): Promise<{ value: string; expiresAt: number } | null> => {
    const res = await fetchImpl(`${API}/app/installations/${installationId}/access_tokens`, {
      method: 'POST',
      headers: await appHeaders(),
      body: JSON.stringify({ repository_ids: [repoId], permissions: { contents: 'write' } }),
    })
    if (res.status !== 201) return null
    const b = (await res.json()) as { token: string; expires_at: string }
    // GitHub returns an ISO 8601 string; the adapter expects epoch ms.
    return { value: b.token, expiresAt: Date.parse(b.expires_at) }
  }

  const mintRepoToken: GitHubClient['mintRepoToken'] = async (userToken, owner, name) => {
    const installationId = await installationForRepo(owner, name)
    if (installationId === 'none') return { ok: false, reason: 'no_repo_access' }

    const repoId = await authorizeUserRepo(userToken, installationId, owner, name)
    if (repoId === null) return { ok: false, reason: 'no_repo_access' }

    const token = await installationToken(installationId, repoId)
    if (!token) return { ok: false, reason: 'error' }
    return { ok: true, value: token.value, expiresAt: token.expiresAt }
  }

  const installUrl: GitHubClient['installUrl'] = async () => {
    const res = await fetchImpl(`${API}/app`, { headers: await appHeaders() })
    if (!res.ok) return null
    const b = (await res.json()) as { html_url: string }
    return b.html_url ? `${b.html_url}/installations/new` : null
  }

  return { exchangeCode, getUser, mintRepoToken, installUrl }
}

const baseHeaders: HeadersInit = {
  accept: 'application/vnd.github+json',
  'x-github-api-version': '2022-11-28',
  'user-agent': 'slideblaster-auth',
}
