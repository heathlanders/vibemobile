# Deploy — vibe-daemon

The daemon binds `127.0.0.1:8787` only; `tailscale serve` is the sole ingress
(PLAN §5 / `docs/security.md` #1 / ADR 0005). These steps are operator actions —
nothing here is run from application code.

## systemd (user unit — what the box runs)

The unit assumes the repo at `~/vibemobile` and Node 20 at the nvm path in
`VIBE_NODE`; set `VIBE_NODE=$(nvm which 20)` in `~/.config/vibe-daemon.env` if
yours differs. Install native modules under that same Node:

```bash
cd vibe-daemon
PATH="$(dirname "$VIBE_NODE"):$PATH" npm install --include=dev   # dev: tsx + types
PATH="$(dirname "$VIBE_NODE"):$PATH" npm rebuild better-sqlite3 node-pty   # after a Node switch

systemd-analyze --user verify deploy/vibe-daemon.service
cp deploy/vibe-daemon.service ~/.config/systemd/user/
loginctl enable-linger "$USER"        # keep running past logout
systemctl --user daemon-reload
systemctl --user enable --now vibe-daemon
journalctl --user -u vibe-daemon -f   # logs
```

`ExecStart` runs `tsx src/server.ts` straight from the checkout (no build step),
so whatever branch is checked out there is what the next restart deploys. The
DB lands at `WorkingDirectory/vibe.db` unless `VIBE_DB` is set. A restart ends
any Claude session running under the daemon, including one driving the deploy.

## Ingress — `tailscale serve` (ADR 0005)

The phone reaches the daemon over the **tailnet**, not the public internet. The
daemon stays bound to `127.0.0.1`; `tailscale serve` proxies it onto the tailnet
with automatic TLS. One-time operator command:

```bash
tailscale serve --bg 8787      # https://<machine>.<tailnet>.ts.net → 127.0.0.1:8787
tailscale serve status         # confirm the mapping
```

Release downloads (proposal 51) are a static dir on the same host, filled by
`scripts/release.sh`. Serving a path needs root:

```bash
sudo tailscale serve --bg --set-path /dl /data/volumes/vibemobile/releases   # → https://<machine>.<tailnet>.ts.net/dl/
```

`--bg` persists across reboots. The hostname is your box's MagicDNS name; the
cert is issued automatically by Tailscale (`*.ts.net`).

Lock it to just your phone with a Tailscale ACL (admin console) — `security.md`
#6. The bearer token is the second layer on top.

Smoke test once served (phone on the tailnet, or from the box itself):

```bash
curl https://<machine>.<tailnet>.ts.net/health                      # {"ok":true}
curl -o /dev/null -w '%{http_code}\n' https://<machine>.<tailnet>.ts.net/projects   # 401 (no token)
```

> WebSocket note: `tailscale serve` proxies WS upgrades (`/pty/:id`,
> `/session/:id`) — verify against a live socket when M2 lands.
