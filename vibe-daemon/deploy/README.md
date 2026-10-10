# Deploy — vibe-daemon

The daemon binds `127.0.0.1:8787` only; `tailscale serve` is the sole ingress
(PLAN §5 / `docs/security.md` #1 / ADR 0005). These steps are operator actions —
nothing here is run from application code.

## systemd (system-scoped, runs as `boss`)

```bash
sudo cp deploy/vibe-daemon.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now vibe-daemon
systemctl status vibe-daemon
journalctl -u vibe-daemon -f      # logs
```

Validate the unit before installing:

```bash
systemd-analyze verify deploy/vibe-daemon.service
```

`ExecStart=/usr/bin/npm start` runs `tsx src/server.ts` (no build step). The DB
lands at `WorkingDirectory/vibe.db` unless `VIBE_DB` is set.

### User-scoped alternative

To run under `systemctl --user` instead (no root), drop the `User=` line, place
the unit in `~/.config/systemd/user/`, and keep the service alive past logout:

```bash
loginctl enable-linger boss
systemctl --user enable --now vibe-daemon
```

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
