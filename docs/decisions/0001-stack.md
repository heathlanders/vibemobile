# ADR 0001 — Stack

**Status:** Accepted (2026-06-08)

## Context

Greenfield. Built by/for a Flutter developer running ~20 projects on a home
Linux server, who lives in the terminal and wants a polished mobile control
plane.

## Decision

- **Client:** Flutter (Android first, iOS later). Riverpod state,
  `web_socket_channel` for streams, `dio` for REST, `xterm.dart` terminal,
  `flutter_secure_storage`, FCM push.
- **Server daemon (`vibe-daemon`):** Node 20 + TypeScript, Fastify +
  `@fastify/websocket`, `better-sqlite3`, `@anthropic-ai/claude-agent-sdk`,
  `node-pty`, run as a systemd service under user `boss`.
- **Transport:** ~~Cloudflare Tunnel (reuse existing `~/.cloudflared`)~~ —
  **superseded by [ADR 0005](0005-tailscale-transport.md): Tailscale.** Daemon
  still binds **localhost only**, device-pairing token auth still applies.

## Consequences

- Matches the user's existing Flutter/Riverpod clean-architecture patterns.
- Node must be bumped **18 → 20** on the box for the latest SDK (`PLAN.md §7`).
- No inbound ports opened; ingress is the sole entry (`PLAN.md §5`) — now
  `tailscale serve`, see [ADR 0005](0005-tailscale-transport.md).
