/**
 * Node http entry for the auth stub. Contract: see node.md.
 *
 * Adapts node:http to the web-standard Request/Response the handler speaks, so
 * the stub runs as a local dev server (behind the web-shell's Vite proxy) and as
 * an in-process instance for integration tests. Multiple Set-Cookie headers are
 * emitted individually (getSetCookie), which the web Headers merge in forEach.
 */
import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http'
import { createAuthStub, type AuthStubOptions } from './handler.ts'

const SKIP_REQUEST_HEADERS = new Set([
  'host',
  'connection',
  'keep-alive',
  'transfer-encoding',
  'upgrade',
  'proxy-connection',
])

export function createAuthStubServer(options: AuthStubOptions = {}): Server {
  const stub = createAuthStub(options)
  return createServer((req, res) => {
    toWebRequest(req)
      .then((request) => stub.handle(request))
      .then((response) => sendWebResponse(res, response))
      .catch(() => {
        res.statusCode = 500
        res.end('auth-stub error')
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

  return new Request(url, { method, headers, body: body as BodyInit | undefined })
}

async function sendWebResponse(res: ServerResponse, web: Response): Promise<void> {
  res.statusCode = web.status
  // Set-Cookie must not be comma-merged; emit each individually.
  const setCookies = web.headers.getSetCookie?.() ?? []
  if (setCookies.length > 0) res.setHeader('set-cookie', setCookies)
  web.headers.forEach((value, key) => {
    if (key.toLowerCase() === 'set-cookie') return
    res.setHeader(key, value)
  })
  if (web.body) {
    res.end(Buffer.from(await web.arrayBuffer()))
  } else {
    res.end()
  }
}

/** Start a server and resolve the port it bound to. */
export function listen(server: Server, port = 0): Promise<number> {
  return new Promise((resolve) => {
    server.listen(port, () => {
      const address = server.address()
      resolve(typeof address === 'object' && address ? address.port : port)
    })
  })
}
