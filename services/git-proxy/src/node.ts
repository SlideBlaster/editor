/**
 * Node http entry for the git proxy. Contract: see node.md.
 *
 * Adapts node:http request/response to the web-standard Request/Response that
 * `handleProxy` speaks. Used for local dev and the browser-git integration test
 * (an in-process instance the test points isomorphic-git's corsProxy at).
 */
import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http'
import { handleProxy, type ProxyOptions } from './handler'

// Hop-by-hop headers must not be reconstructed onto the web Request.
const SKIP_REQUEST_HEADERS = new Set([
  'host',
  'connection',
  'keep-alive',
  'transfer-encoding',
  'upgrade',
  'proxy-connection',
])

export function createProxyServer(options: ProxyOptions = {}): Server {
  return createServer((req, res) => {
    toWebRequest(req)
      .then((request) => handleProxy(request, options))
      .then((response) => sendWebResponse(res, response))
      .catch(() => {
        res.statusCode = 502
        res.end('proxy error')
      })
  })
}

async function toWebRequest(req: IncomingMessage): Promise<Request> {
  const url = `http://${req.headers.host ?? 'localhost'}${req.url ?? '/'}`
  const method = req.method ?? 'GET'

  const headers = new Headers()
  for (const [key, value] of Object.entries(req.headers)) {
    if (value === undefined || SKIP_REQUEST_HEADERS.has(key.toLowerCase())) continue
    if (Array.isArray(value)) value.forEach((v) => headers.append(key, v))
    else headers.set(key, value)
  }

  let body: Uint8Array | undefined
  if (method !== 'GET' && method !== 'HEAD') {
    const chunks: Buffer[] = []
    for await (const chunk of req) chunks.push(chunk as Buffer)
    body = Buffer.concat(chunks)
  }

  // Cast: Node's undici and lib.dom disagree on whether a Uint8Array is a valid
  // BodyInit, though both accept it at runtime.
  return new Request(url, { method, headers, body: body as BodyInit | undefined })
}

async function sendWebResponse(res: ServerResponse, web: Response): Promise<void> {
  res.statusCode = web.status
  web.headers.forEach((value, key) => res.setHeader(key, value))
  if (web.body) {
    res.end(Buffer.from(await web.arrayBuffer()))
  } else {
    res.end()
  }
}

/** Start a proxy server and resolve the port it bound to. */
export function listen(server: Server, port = 0): Promise<number> {
  return new Promise((resolve) => {
    server.listen(port, () => {
      const address = server.address()
      resolve(typeof address === 'object' && address ? address.port : port)
    })
  })
}
