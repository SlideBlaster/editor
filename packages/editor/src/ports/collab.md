# Collab port

Live multiplayer over the document model: session lifecycle, CRDT transport, and
awareness. Entirely absent for solo editing — solo and cross-device use need only
git of markdown (ADR 0008/0011).

## Contract

- The editor core binds the AST to a Yjs `Y.Doc` (ADR 0011) and hands it in as an
  opaque `CollabDoc`; this port only moves updates and presence, it does not define
  the binding.
- `startSession` seeds a live session; `join` attaches to an existing one. Two
  `mode`s share one CRDT (ADR 0012): `p2p` (free, y-webrtc, owner-anchored commit)
  and `server` (premium, y-websocket to Phoenix, server single-writer).
- `join` authorizes via an identity-scoped token from the Auth service by default,
  or an opt-in per-session link capability. The signaling/websocket layer admits
  only authorized identities and enforces owner-pays seat caps.
- `awareness` carries ephemeral cursors, selections, and live-drag streaming; it is
  never part of the persisted document. A drag writes one final value on drop.
- The CRDT is session-scoped and never persisted; materialization to markdown and
  the commit belong to the Git port.

## Adapters

Browser and native both use y-webrtc (P2P) or y-websocket to Phoenix (premium).
No managed variant. See `design/architecture/collab.md`.
