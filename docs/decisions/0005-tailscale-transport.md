# ADR 0005 — Tailscale transport (supersedes 0001's transport choice)

**Status:** Accepted (2026-06-09). Supersedes the **Transport** line of
[ADR 0001](0001-stack.md); the rest of 0001 (client, daemon stack) stands.

## Context

ADR 0001 picked Cloudflare Tunnel on the user's existing `flipstack.app` domain
as ingress. Two things surfaced that move the decision:

1. **Sole user, no public sharing.** Only the owner's phone ever connects. A
   public HTTPS endpoint on the internet is a security surface bought for a
   sharing need that doesn't exist.
2. **The real requirement is session durability, not reach.** The user already
   reaches the box fine over Tailscale (Termius/SSH). The pain is that SSH
   sessions die on connection drop (shell is an SSH-session child → `SIGHUP`).
   That's solved by [ADR 0004](0004-tmux-backed-pty.md) + M2 reattach, *not* by
   the choice of front door. The front door only needs to be private and stable.
3. Piggybacking the live `flipstack` tunnel meant a shared blast radius — a bad
   edit to `/etc/cloudflared` could take down `bg.flipstack.app` too. The user
   wanted this to be its own thing.

## Decision

**Transport = Tailscale.** The box and the phone are already on the same tailnet.

- **Daemon still binds `127.0.0.1` only** — unchanged from 0001, security
  invariant #1 (`security.md`) preserved. The daemon is never on the LAN or the
  public internet.
- **Ingress = `tailscale serve`**, not a public tunnel. One operator command
  proxies the loopback port onto the tailnet with automatic TLS:
  ```
  tailscale serve --bg 8787      # https://<machine>.<tailnet>.ts.net → 127.0.0.1:8787
  ```
  WebSocket upgrades (`/pty/:id`, `/session/:id`) proxy through unchanged —
  verify against a live WS when M2 lands.
- **Network boundary = the tailnet.** Only devices the owner has added (and
  permitted via a Tailscale ACL) can resolve or reach the daemon. The
  device-pairing **bearer token stays** as a second, app-level layer.
- **No domain, no Cloudflare, not `flipstack`.** Drops that whole dependency.

## Consequences

- Security model gets *simpler and stronger*: the daemon is invisible to the
  public internet entirely. `security.md` #1 reframes "tunnel = sole ingress" →
  "`tailscale serve` = sole ingress"; #6 (Cloudflare Access OTP) is dropped in
  favor of Tailscale ACLs.
- TLS is automatic (`*.ts.net` MagicDNS cert) — phone gets a valid cert, no
  self-signed handling in the Flutter client.
- Stable hostname (`<machine>.<tailnet>.ts.net`) — survives the box's IP changes,
  no DDNS.
- **Tradeoff:** the app only works while the phone is on the tailnet (Tailscale
  app installed, always-on — acceptable for a personal tool). If public,
  VPN-less sharing is ever wanted, revisit with a dedicated tunnel + own domain.
- `~/.cloudflared` and the `vibe.flipstack.app` hostname are **not** used; the
  M1 "permanent tunnel hostname" task is replaced by a one-time `tailscale serve`.
- No daemon code change — `server.ts` keeps `HOST = 127.0.0.1`.
