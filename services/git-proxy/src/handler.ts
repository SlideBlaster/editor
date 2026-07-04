/**
 * Runtime-agnostic CORS proxy for browser git. Contract: see handler.md.
 *
 * Built on web-standard Request/Response/fetch so the same core runs on a
 * Cloudflare Worker and under Node (via node.ts). It exists only because GitHub's
 * git-smart-http endpoints are not CORS-enabled; it is deliberately minimal and
 * non-logging because a short-lived repo-scoped token transits it (auth.md).
 */

/** Only github.com git-smart-http is proxied. Nothing else is reachable. */
const DEFAULT_ALLOWED_HOST = 'github.com'

/** `/{owner}/{repo}[.git]/{info/refs | git-upload-pack | git-receive-pack}` */
const ALLOWED_PATH = /^\/[^/]+\/[^/]+\/(info\/refs|git-upload-pack|git-receive-pack)$/

const ALLOW_METHODS = 'GET, POST, OPTIONS'

// Request headers we forward upstream. Authorization is forwarded but never logged.
const FORWARD_REQUEST_HEADERS = new Set([
  'accept',
  'accept-encoding',
  'accept-language',
  'authorization',
  'cache-control',
  'content-type',
  'git-protocol',
  'pragma',
  'range',
  'user-agent',
])

// Response headers we surface back to the browser. Body-framing headers
// (content-encoding, content-length, transfer-encoding) are deliberately NOT
// forwarded: fetch auto-decompresses the body, so the stale values would make the
// client double-decode. The runtime re-derives them for the re-emitted stream.
const FORWARD_RESPONSE_HEADERS = new Set([
  'accept-ranges',
  'cache-control',
  'content-type',
  'date',
  'etag',
  'expires',
  'last-modified',
  'location',
  'vary',
])

const ALLOW_HEADERS = [
  'accept',
  'accept-encoding',
  'accept-language',
  'authorization',
  'cache-control',
  'content-type',
  'git-protocol',
  'pragma',
  'range',
  'user-agent',
].join(', ')

const EXPOSE_HEADERS = [...FORWARD_RESPONSE_HEADERS].join(', ')

export interface ProxyOptions {
  /** Host allowlist; defaults to github.com. Overridable for tests. */
  allowedHost?: string
}

/**
 * Handle one proxied git request. Resolves the target from the path
 * (`/{host}/{owner}/{repo}/...` as isomorphic-git's corsProxy encodes it),
 * enforces the host + endpoint allowlist, forwards a curated header set, and
 * returns the upstream response with CORS headers attached.
 */
export async function handleProxy(request: Request, options: ProxyOptions = {}): Promise<Response> {
  const allowedHost = options.allowedHost ?? DEFAULT_ALLOWED_HOST
  const origin = request.headers.get('origin') ?? '*'

  if (request.method === 'OPTIONS') return preflight(origin)
  if (request.method !== 'GET' && request.method !== 'POST') {
    return deny(origin, 405, 'method not allowed')
  }

  const target = resolveTarget(request, allowedHost)
  if (!target) return deny(origin, 403, 'forbidden target')

  const forwardHeaders = new Headers()
  request.headers.forEach((value, key) => {
    if (FORWARD_REQUEST_HEADERS.has(key.toLowerCase())) forwardHeaders.set(key, value)
  })

  const body = request.method === 'POST' ? await request.arrayBuffer() : undefined
  const upstream = await fetch(target.toString(), {
    method: request.method,
    headers: forwardHeaders,
    body,
    redirect: 'follow',
  })

  const responseHeaders = new Headers()
  upstream.headers.forEach((value, key) => {
    if (FORWARD_RESPONSE_HEADERS.has(key.toLowerCase())) responseHeaders.set(key, value)
  })
  responseHeaders.set('access-control-allow-origin', origin)
  responseHeaders.set('access-control-expose-headers', EXPOSE_HEADERS)
  responseHeaders.append('vary', 'origin')

  return new Response(upstream.body, { status: upstream.status, headers: responseHeaders })
}

/**
 * Reconstruct the upstream URL from the request path and validate it against the
 * host + endpoint allowlist. Returns null (caller denies) on anything unexpected.
 */
export function resolveTarget(request: Request, allowedHost: string): URL | null {
  const url = new URL(request.url)
  const rest = url.pathname.replace(/^\/+/, '')
  if (rest === '') return null

  const targetString = /^https?:\/\//i.test(rest)
    ? rest + url.search
    : `https://${rest}${url.search}`

  let target: URL
  try {
    target = new URL(targetString)
  } catch {
    return null
  }

  if (target.protocol !== 'https:') return null
  if (target.hostname !== allowedHost) return null
  if (!ALLOWED_PATH.test(target.pathname)) return null
  return target
}

function preflight(origin: string): Response {
  return new Response(null, {
    status: 204,
    headers: {
      'access-control-allow-origin': origin,
      'access-control-allow-methods': ALLOW_METHODS,
      'access-control-allow-headers': ALLOW_HEADERS,
      'access-control-max-age': '600',
      vary: 'origin',
    },
  })
}

function deny(origin: string, status: number, message: string): Response {
  return new Response(message, {
    status,
    headers: {
      'access-control-allow-origin': origin,
      'content-type': 'text/plain',
      vary: 'origin',
    },
  })
}
