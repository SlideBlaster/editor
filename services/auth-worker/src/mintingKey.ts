/**
 * The KMS-swappable signing seam (ADR 0010/0020). Contract: mintingKey.md.
 *
 * The GitHub App private key is the crown jewel. Everything above this module
 * asks only for an RS256 signature and is blind to where the key lives:
 *
 *   - `createLocalMintingKey` — imports the App `.pem` as a WebCrypto `CryptoKey`
 *     (dev / self-host; key in a Worker Secret).
 *   - (later) a KMS key — an HTTPS call to GCP/AWS KMS `asymmetricSign`; the key
 *     never leaves the KMS. Swapping it in touches only this module.
 */
import { bytesFromBase64 } from './encoding'

export interface MintingKey {
  /** RS256-sign the JWT signing input; returns the raw signature bytes. */
  sign(signingInput: string): Promise<Uint8Array>
  keyId(): string | null
}

export function createLocalMintingKey(pem: string): MintingKey {
  let cached: Promise<CryptoKey> | null = null
  const key = () => (cached ??= importRsaPrivateKey(pem))
  return {
    async sign(signingInput) {
      const signature = await crypto.subtle.sign(
        'RSASSA-PKCS1-v1_5',
        await key(),
        new TextEncoder().encode(signingInput),
      )
      return new Uint8Array(signature)
    },
    keyId: () => null,
  }
}

/**
 * Import an RSA private key PEM for RS256 signing. WebCrypto only accepts PKCS#8;
 * GitHub hands out PKCS#1 ("BEGIN RSA PRIVATE KEY"), so wrap those to PKCS#8 first.
 */
async function importRsaPrivateKey(pem: string): Promise<CryptoKey> {
  if (!pem || !pem.includes('PRIVATE KEY')) {
    throw new Error('APP_PRIVATE_KEY is empty or not a PEM private key')
  }
  const der = derFromPem(pem)
  const pkcs8 = pem.includes('BEGIN RSA PRIVATE KEY') ? wrapPkcs1AsPkcs8(der) : der
  return crypto.subtle.importKey(
    'pkcs8',
    pkcs8,
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign'],
  )
}

/** Strip PEM armor + whitespace and base64-decode to DER. */
function derFromPem(pem: string): Uint8Array<ArrayBuffer> {
  const body = pem
    .replace(/-----BEGIN [^-]+-----/, '')
    .replace(/-----END [^-]+-----/, '')
    .replace(/\s+/g, '')
  return bytesFromBase64(body)
}

/**
 * Wrap a PKCS#1 RSAPrivateKey DER in a PKCS#8 PrivateKeyInfo:
 *   SEQUENCE { INTEGER 0, SEQUENCE { OID rsaEncryption, NULL }, OCTET STRING(pkcs1) }
 */
function wrapPkcs1AsPkcs8(pkcs1: Uint8Array): Uint8Array<ArrayBuffer> {
  // AlgorithmIdentifier for rsaEncryption (1.2.840.113549.1.1.1) + NULL params.
  const algId = [
    0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00,
  ]
  const version = [0x02, 0x01, 0x00]
  const privateKey = [0x04, ...derLength(pkcs1.length), ...pkcs1] // OCTET STRING
  const body = [...version, ...algId, ...privateKey]
  const seq = [0x30, ...derLength(body.length), ...body]
  return Uint8Array.from(seq)
}

/** DER definite-length encoding for a length `n`. */
function derLength(n: number): number[] {
  if (n < 0x80) return [n]
  const bytes: number[] = []
  for (let x = n; x > 0; x = Math.floor(x / 256)) bytes.unshift(x % 256)
  return [0x80 | bytes.length, ...bytes]
}
