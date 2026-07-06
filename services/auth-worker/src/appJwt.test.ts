/**
 * Proves the homegrown App-JWT path end to end on the Workers crypto surface: a
 * real RSA key in GitHub's PKCS#1 PEM format, signed via `MintingKey` (which wraps
 * PKCS#1 → PKCS#8 for WebCrypto), yields a structurally-valid RS256 JWT whose
 * signature verifies against the public key.
 */
import { generateKeyPairSync } from 'node:crypto'
import { describe, expect, it } from 'vitest'
import type { AuthConfig } from './config'
import { generateAppJwt } from './appJwt'
import { createLocalMintingKey } from './mintingKey'

const config: AuthConfig = {
  githubAppId: '4228880',
  githubClientId: 'Iv1.testclientid',
  githubClientSecret: '',
  appPrivateKey: '',
  webShellOrigin: 'http://localhost:5173',
  secureCookies: false,
  sameSite: 'Lax',
}

function bytesFromBase64url(s: string): Uint8Array<ArrayBuffer> {
  const b64 = s.replace(/-/g, '+').replace(/_/g, '/')
  const bin = atob(b64.padEnd(Math.ceil(b64.length / 4) * 4, '='))
  return Uint8Array.from(bin, (c) => c.charCodeAt(0))
}

function derFromPem(pem: string): Uint8Array<ArrayBuffer> {
  const body = pem.replace(/-----[^-]+-----/g, '').replace(/\s+/g, '')
  return Uint8Array.from(atob(body), (c) => c.charCodeAt(0))
}

describe('generateAppJwt', () => {
  it('produces a valid, verifiable RS256 JWT from a PKCS#1 App key', async () => {
    // GitHub hands out PKCS#1 ("BEGIN RSA PRIVATE KEY"); mirror that exactly.
    const { privateKey, publicKey } = generateKeyPairSync('rsa', {
      modulusLength: 2048,
      privateKeyEncoding: { type: 'pkcs1', format: 'pem' },
      publicKeyEncoding: { type: 'spki', format: 'pem' },
    })
    expect(privateKey).toContain('BEGIN RSA PRIVATE KEY')

    const jwt = await generateAppJwt(
      { ...config, appPrivateKey: privateKey },
      createLocalMintingKey(privateKey),
    )
    const [h, p, s] = jwt.split('.')
    expect(h && p && s).toBeTruthy()

    const header = JSON.parse(new TextDecoder().decode(bytesFromBase64url(h!)))
    const claims = JSON.parse(new TextDecoder().decode(bytesFromBase64url(p!)))
    expect(header.alg).toBe('RS256')
    expect(claims.iss).toBe('Iv1.testclientid')
    expect(claims.exp - claims.iat).toBeLessThanOrEqual(600)

    const verifyKey = await crypto.subtle.importKey(
      'spki',
      derFromPem(publicKey),
      { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
      false,
      ['verify'],
    )
    const ok = await crypto.subtle.verify(
      'RSASSA-PKCS1-v1_5',
      verifyKey,
      bytesFromBase64url(s!),
      new TextEncoder().encode(`${h}.${p}`),
    )
    expect(ok).toBe(true)
  })

  it('throws cleanly when the key is missing', async () => {
    await expect(generateAppJwt(config, createLocalMintingKey(''))).rejects.toThrow()
  })
})
