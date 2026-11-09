---
status: proposed
updated: 2026-11-06
---

# `/cap` WebSocket: capability and extension envelope (`slideblaster.cap/1`)

`sb serve <dir>` exposes one WebSocket endpoint, `ws://<host>:<port>/cap`, through
which the web host reaches the native machine: project storage, file-change
notifications and extension providers (`block.render`). This document is the contract
between `sb serve` (lane B) and the web host's providers client (lane C). It
implements design `docs/architecture/alpha.md` sections 2 and 4.

Rules inherited from the design: the host never computes meaning; every mutation is
an exact-byte write with a precondition; results are accepted only when the echoed
`ticket` and `fingerprint` match the request.

## 1. Framing

- One JSON object per WebSocket **text** frame (UTF-8). Binary frames are not used.
- Bytes (file contents, binary artifacts) are base64 (RFC 4648, with padding) in
  fields whose names end in `Base64`. Text artifacts (SVG) are also available as
  `data` with `encoding: "utf8"`.
- Unknown request fields are ignored by the server; the server never sends a field
  not listed here without bumping the protocol string.
- Paths are **project-relative, `/`-separated, no leading `/`, no `..` segments, no
  empty segments**. The empty string is the project root. A violating path yields
  error `bad_path`. Paths under `.slideblaster/cache/` are not readable or writable
  through `storage.*` (error `forbidden`); `.git/` is not listable.

## 2. Messages

### 2.1 Requests (client to server)

```json
{ "id": 7, "op": "storage.read", "path": "talk.slideBlaster.md" }
```

`id` is any JSON number or string chosen by the client, echoed in the response.
Requests may be pipelined; responses may arrive out of order (a compile does not
block a read).

### 2.2 Responses (server to client)

```json
{ "id": 7, "ok": true,  ...result fields }
{ "id": 7, "ok": false, "error": { "code": "not_found", "message": "..." } }
```

Error codes: `bad_request`, `bad_path`, `forbidden`, `not_found`, `conflict`,
`io_error`, `unknown_op`, `fingerprint_mismatch`, `too_large`.

### 2.3 Events (server to client, unsolicited)

```json
{ "event": "hello", "protocol": "slideblaster.cap/1", "version": "0.2.0", "root": "unit",
  "providers": [ ...Provider ] }
{ "event": "watch", "changes": [ { "path": "figures/a.tikz", "change": "modified" } ] }
```

`hello` is sent once, immediately after the connection opens. `change` is one of
`created`, `modified`, `deleted`. `watch` events are sent only after
`watch.subscribe`; they are batched (at most one per poll interval, default 400 ms)
and exclude `.slideblaster/` and `.git/`. They report changes made by anybody,
including this connection's own `storage.save`.

`Provider` (from the loaded extension manifests):

```json
{ "id": "sb.tex", "version": "0.2.0", "slot": "block.render",
  "kinds": ["tikz", "tex"], "output": "image/svg+xml",
  "available": true, "missingTools": [] }
```

`available` is false when a tool listed in the manifest `needs` is not on `PATH`;
`missingTools` names them. An unavailable provider still answers requests (with typed
absence, section 4).

## 3. Operations

### `ping`
Response: `{ "id": 1, "ok": true }`.

### `storage.list`
Request: `{ "op": "storage.list", "path": "" , "recursive": true }`
(`path` defaults to the root, `recursive` to false). Response:

```json
{ "ok": true, "entries": [ { "path": "talk.slideBlaster.md", "kind": "file", "size": 1234 },
                           { "path": "figures", "kind": "dir" } ] }
```

Entries are sorted by path. Symlinks are listed as the kind of their target; links
leaving the project root are omitted.

### `storage.read`
Request: `{ "op": "storage.read", "path": "figures/a.tikz" }`. Response:

```json
{ "ok": true, "path": "figures/a.tikz", "size": 321,
  "sha256": "<hex>", "contentBase64": "..." }
```

Errors: `not_found`, `too_large` (limit 32 MiB), `io_error`.

### `storage.save`
Conditional replacement (the native `compareAndReplace`). Request:

```json
{ "op": "storage.save", "path": "talk.slideBlaster.md",
  "expectedBase64": "<current bytes>", "contentBase64": "<new bytes>" }
```

- `expectedBase64` present: the file must exist and its bytes must equal the expected
  bytes, else error `conflict` (nothing written).
- `expectedBase64` is `null` or absent: the file must **not** exist (create), else
  `conflict`. Missing parent directories are created.
- A write whose new bytes equal the expected bytes is a successful no-op.

Response: `{ "ok": true, "path": "...", "sha256": "<hex of new bytes>", "size": 99 }`.
The server writes through a temporary sibling and renames; permissions are kept.

### `watch.subscribe` / `watch.unsubscribe`
`{ "op": "watch.subscribe" }` starts `watch` events for this connection (whole project
tree). Response: `{ "ok": true }`. Idempotent.

### `providers.list`
Response: `{ "ok": true, "providers": [ ...Provider ] }` (same as `hello`).
Extension manifests are reloaded from disk on each call, so a newly dropped
`.slideblaster/extensions/<id>/extension.json` is picked up without a restart.
The response also carries `problems: [{path, message}]` for manifests that failed
strict validation (they are skipped, never fatal).

### `block.render`
The extension envelope of the design, section 4.2:
`{ticket, slot, kind, fingerprint, input, deadline}` in, `{ticket, fingerprint,
artifact | diagnostics}` out. Request:

```json
{ "id": 9, "op": "block.render",
  "ticket": "t-41", "slot": "block.render", "kind": "tikz",
  "fingerprint": "<64 hex, optional>",
  "deadline": 60000,
  "input": {
    "body": "\\begin{tikzpicture} ... \\end{tikzpicture}",
    "preamble": "\\usepackage{pifont}",
    "palette": [ { "name": "palCoral", "hex": "FF595E" } ],
    "width": 960,
    "inputs": [ { "path": "figures/part.tex", "contentBase64": "..." } ],
    "lineMap": { "file": "figures/a.tikz", "firstLine": 1 }
  } }
```

- `input` is the *block request*: `body` is the block source (a bare picture or a full
  `tikzpicture`), `preamble` the deck preamble (LaTeX), `palette` the theme colours
  (emitted as `\definecolor{name}{HTML}{HEX}`), `width` the requested render width in
  CSS px (part of the fingerprint; not used to scale the TeX), `inputs` the resolved
  `\input` closure (workspace files the body refers to, read by the broker through
  `storage.read`; `path` is the name exactly as the body writes it, with `.tex`
  added when TeX would add it, and the file is written under that name in the
  throwaway compile directory so `\input{figures/part}` resolves), `lineMap` how to translate TeX error lines back to source lines.
  All of `preamble`, `palette`, `width`, `inputs`, `lineMap` are optional.
- `fingerprint` is optional. If present the server recomputes it from the block
  request and the provider id and version; a difference is error
  `fingerprint_mismatch` (the request is not run). If absent the server uses its own.
  The algorithm is a pure function in `slideblaster-extension` shared by Wasm and
  native: SHA-256 over a length-prefixed canonical encoding of
  `(provider id, provider version, kind, body, preamble, palette, width,
  inputs sorted by path)`, lower-case hex.
- `deadline` is a budget in milliseconds, clamped to the provider manifest's
  `limits.timeoutMs` (the smaller wins). Optional.
- `slot` must be `block.render`. `kind` selects the provider (`tikz`, `tex`, `dot`,
  or whatever manifests provide). Unknown kind: typed absence `no_provider`.

Response (success; `cached` true on a cache hit, in which case no process ran):

```json
{ "id": 9, "ok": true, "ticket": "t-41", "fingerprint": "<hex>",
  "artifact": { "mime": "image/svg+xml", "encoding": "utf8", "data": "<svg ...>",
                "size": 4821,
                "provenance": { "provider": "sb.tex", "version": "0.2.0", "cached": false,
                                "elapsedMs": 812 } },
  "diagnostics": [] }
```

For `encoding: "base64"` (non-text artifacts) `data` is base64. The artifact bytes
are exactly what is cached at
`<project>/.slideblaster/cache/<provider>/<fingerprint>`.

Response (compile failure): `ok` is still `true` at the protocol level (the request
was served); there is no `artifact`:

```json
{ "id": 9, "ok": true, "ticket": "t-41", "fingerprint": "<hex>",
  "diagnostics": [ { "severity": "error", "code": "tex.error",
                     "message": "Undefined control sequence.",
                     "texLine": 23, "sourceLine": 14, "file": "figures/a.tikz" } ] }
```

`message` is the first TeX `! ...` line without the `! ` prefix. `sourceLine` is
present when the failing line maps to a `%%sb-line` marker (1-based, relative to the
block source plus `lineMap.firstLine - 1`). Failures are not cached.

## 4. Typed absence

A missing tool or provider is a result, not a transport error. The deck must still
open, save and export; the host paints a labelled placeholder and surfaces the
diagnostic:

```json
{ "id": 9, "ok": true, "ticket": "t-41", "fingerprint": "<hex>",
  "absence": { "reason": "tool_missing", "provider": "sb.tex", "tool": "dvisvgm" },
  "diagnostics": [ { "severity": "warning", "code": "provider.absent",
                     "message": "dvisvgm is not installed; cannot render tikz" } ] }
```

`absence.reason` is `tool_missing` (a `needs` tool not on `PATH`), `no_provider` (no
manifest provides `kind`), `timeout`, or `limit_exceeded` (output over
`limits.maxBytes`; the last two carry no `tool`). An absence is never cached.

## 5. Other operations

### `broker.stats`
`{ "ok": true, "requests": 5, "cacheHits": 2, "runs": 3 }` for this server process.
Used by tests to prove a second identical request is a cache hit.

## 6. HTTP side of `sb serve`

- `GET /` and any path not starting with `/cap` or `/project/`: static files from the
  packaged web host directory (`--web <dir>`; default `hosts/web/dist` relative to
  the executable's data directory, then the repository checkout). `/` serves
  `index.html`. Unknown file: 404. If no web directory exists a built-in placeholder
  page is served at `/` that states how to supply one.
- `GET /project/<path>`: read-only raw project file (for `<img src>` of workspace
  assets), same path rules and `.slideblaster/cache` restriction as `storage.read`,
  with a `Content-Type` guessed from the extension.
- `GET /cap-info`: `200` JSON `{ "protocol": "slideblaster.cap/1", "root": "<name>" }`
  (a cheap probe the host can use before opening the socket).
- `POST /export/pdf?entry=<deck path in the project>[&steps=1]`: build the deck as a PDF (the
  `sb build --pdf` pipeline, see `slideblaster-md-alpha.md`, "Building") and write
  `<deck>.pdf` next to the deck, replacing an earlier one. `200` JSON
  `{ "ok": true, "path": "<absolute path>", "name": "<file name>" }`; on failure `{ "ok": false,
  "error": "<reason>" }` with `400` (bad entry: it must be a relative `.slideBlaster.md` path
  inside the project), `404` (no such deck) or `500` (no Chrome found, Chrome failed, the deck did
  not render). The request is refused with `403` unless its `Origin` header is absent or loopback
  (same rule as the WebSocket), so another web page cannot make the server write files. The
  reply comes when the PDF is written (a few seconds). The web host's **Export PDF** button
  saves unsaved edits, calls this endpoint and shows the path in the status bar (Shift-click:
  `steps=1`).
- The server binds `127.0.0.1` only. WebSocket upgrades are accepted only when the
  `Origin` header is absent or its host is the bound address, `localhost` or
  `127.0.0.1` (blocks cross-site WebSocket hijacking).

## 7. Process lifecycle and `/session`

`sb serve <dir> [--port N] [--web <dir>] [--exit-on-stdin-eof]`:

- `--port 0` binds a free loopback port. Once listening, the process prints exactly
  one line `SB_READY port=NNNN` on standard output (flushed); human logs go to
  standard error. A supervisor (the desktop shell) waits for that line.
- It stops cleanly (exit 0) on SIGTERM or SIGINT, and, only with
  `--exit-on-stdin-eof`, when standard input reaches end of file. (Opt-in because a
  background run with stdin redirected from `/dev/null` must not exit at once.)
- `/session` is mounted on the same port and carries `slideblaster.session/1`
  (`docs/specs/session-v1-protocol.md`), one frame per message, with unsolicited
  `view_updated` pushes. It needs a deck analyzer linked into the executable
  (`CliHooks.hookAnalyzer`); without one the upgrade is refused with a reason.
  Inside the process the session driver calls the same broker and cache as `/cap`
  `block.render`; the fingerprint it relays is the core's, so the broker computes its
  own (provider-salted) one and ignores the claimed one on that path.

## 8. Defaults (revisitable)

Poll interval 400 ms; read limit 32 MiB; binary frames unused; base64 for all file
bytes; one provider per `(slot, kind)`; priority is workspace manifests, then user-level
(`$XDG_CONFIG_HOME/slideblaster/extensions`), then built-ins.
