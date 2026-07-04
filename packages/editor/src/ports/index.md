# ports (barrel)

Re-exports the six port interfaces and their supporting types. The editor core
imports capabilities only from here; adapters implement these interfaces.

| Port    | Responsibility                                                | ADR        |
| ------- | ------------------------------------------------------------- | ---------- |
| Storage | working copy: list/read/write/watch files + assets            | 0008       |
| Git     | status/stage/commit/log/diff/branch/merge/clone/pull/push     | 0001, 0008 |
| Auth    | identity + short-lived repo-scoped tokens; capability flags   | 0010       |
| Collab  | session lifecycle + CRDT transport + awareness (off for solo) | 0011, 0012 |
| Compile | table -> HTML now; general LaTeX deferred                     | 0009       |
| Export  | PDF + standalone presenter HTML from rendered slides          | 0009       |

Bundled into the core with no port: the TikZ renderer, KaTeX, fonts (ADR 0003).
