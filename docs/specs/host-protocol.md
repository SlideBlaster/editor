---
status: proposed
updated: 2026-07-23
---

# Browser host protocol v1

The web adapter crosses one versioned asynchronous host boundary:

```text
Haskell Wasm
  -> globalThis.slideblasterHost.call(request)
  -> browser capability
  -> structured response
  -> Haskell Wasm
```

## Envelope

Requests and responses are JSON objects.

```json
{
  "version": 1,
  "id": 42,
  "capability": "storage",
  "operation": "read",
  "payload": {}
}
```

```json
{
  "version": 1,
  "id": 42,
  "ok": true,
  "payload": {}
}
```

An error response is:

```json
{
  "version": 1,
  "id": 42,
  "ok": false,
  "error": {
    "code": "not-found",
    "message": "The requested project file does not exist."
  }
}
```

Unknown versions, capabilities, operations, and malformed payloads are rejected.
The host converts browser exceptions into structured errors. Source contents,
credentials, and tokens are never logged.

Envelope request identifiers are non-negative JSON safe integers from `0`
through `9007199254740991`. Success contains `payload` and no `error`; failure
contains `error` and no `payload`. The error object has exactly `code` and
`message`.

## Initial capabilities

| Operation | Request payload | Success payload |
| --- | --- | --- |
| `log.write` | `{ "level": "debug" | "info" | "warn" | "error", "message": string, "context": any }` | `{ "written": true }` |
| `storage.list` | `{}` | `{ "paths": string[] }` |
| `storage.read` | `{ "path": string }` | `{ "text": string | null }` |
| `storage.write` | `{ "path": string, "text": string }` | `{ "stored": true }` |
| `measure.text` | `{ "text": string, "font": string, "maxWidth": number | null }` | `{ "width": number, "height": number, "lines": number }` |

Storage paths are non-empty, normalized, workspace-relative forward-slash
paths. They cannot contain empty, `.` or `..` segments, cannot start with `/`,
cannot contain `\`, and are limited to 240 characters. `storage.read` uses
`null` for an absent path.

`measure.text` accepts a positive finite width or `null`; its output is derived
layout evidence and never source authority.

Stable host-generated failure categories currently include
`invalid_request`, `unsupported_protocol`, `unsupported_capability`,
`invalid_payload`, `invalid_storage_path`, `invalid_log_level`, and
`browser_failure`.

Git, collaboration, compile, download, and printing enter only with the vertical
slice that uses them.

The envelope implementation is complete. Capability payload schemas remain
proposed until closed-object validation and fixtures cover each operation.
