# service: collab

The Collab service (Phoenix). P2P signaling + STUN for the free tier;
server-authoritative sessions with a Postgres WAL and single-writer commit
serialization for premium.

Not a pnpm package (Elixir). Design: `design/architecture/collab.md`, ADR 0012.
Stood up at M6/M7.
