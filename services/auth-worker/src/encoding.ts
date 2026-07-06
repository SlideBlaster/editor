/**
 * Base64url + random-token helpers shared across the Worker. Contract: encoding.md.
 *
 * Web-standard only (`atob`/`btoa`/`crypto.getRandomValues`) so the same code runs
 * on the Workers runtime and under Node (tests).
 */

/** Decode a standard base64 string to bytes (ArrayBuffer-backed for WebCrypto). */
export function bytesFromBase64(b64: string): Uint8Array<ArrayBuffer> {
  const bin = atob(b64)
  const out = new Uint8Array(bin.length)
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i)
  return out
}

/** Encode bytes as base64url (no padding) — the JWT segment encoding. */
export function base64urlFromBytes(bytes: Uint8Array): string {
  let bin = ''
  for (const b of bytes) bin += String.fromCharCode(b)
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

/** Encode a UTF-8 string as base64url (no padding). */
export function base64urlFromString(s: string): string {
  return base64urlFromBytes(new TextEncoder().encode(s))
}

/** A 256-bit URL-safe random token (session id, csrf, OAuth state). */
export function randomToken(): string {
  const bytes = new Uint8Array(32)
  crypto.getRandomValues(bytes)
  return base64urlFromBytes(bytes)
}
