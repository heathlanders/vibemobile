# VibeMobile

An Android app + Node/TypeScript daemon to manage software projects, terminals,
and [Claude Code](https://claude.com/claude-code) sessions on a home Linux server
— reached privately over [Tailscale](https://tailscale.com).

The point: **terminal sessions that survive a dropped connection.** Each session
lives in `tmux` on the server, decoupled from any socket, so when your phone
roams WiFi↔cellular the shell keeps running and the app re-attaches — no lost
work, no typing `tmux`.

> Status: **M2 in progress.** M0/M1 complete. The daemon engine and Flutter
> client are built and tested; only the on-device roam test remains. See
> [`docs/milestones.md`](docs/milestones.md).

## Architecture

```
phone (Tailscale on) ──► https://<machine>.<tailnet>.ts.net  (tailscale serve)
                          └─► 127.0.0.1:8787  vibe-daemon (localhost-bound)
                                ├─ auth: device pairing + bearer token
                                ├─ SQLite: devices, projects, sessions, events
                                ├─ scanner: lists projects under the roots
                                └─ tmux -L vibe: durable terminal sessions
```

- **Client** (`app/`) — Flutter, Riverpod, `xterm` terminal, `dio`,
  `flutter_secure_storage`, `web_socket_channel`.
- **Daemon** (`vibe-daemon/`) — Node 20 + TypeScript, Fastify + `@fastify/websocket`,
  `better-sqlite3`, `node-pty`, `@anthropic-ai/claude-agent-sdk`, run via `tsx`.
- **Transport** — Tailscale (ADR 0005). Daemon binds localhost only; the tailnet
  is the network boundary, the bearer token a second layer. No public endpoint.

`docs/` is the source of truth: ADRs in `docs/decisions/`, wire specs in
`docs/protocols/`, progress in `docs/milestones.md`, the security checklist in
`docs/security.md`. `.claude/docs-map.md` routes you to the right doc per change.

## Repo layout

| Path | What |
|------|------|
| `vibe-daemon/` | The server daemon (separate workspace) |
| `app/` | The Flutter client (separate workspace) |
| `docs/` | Decisions, protocols, milestones, security — the running record |
| `PLAN.md` | The master plan: goal, architecture, milestones |
| `CLAUDE.md` | How Claude works in this repo |

## Daemon — run it

Requires Node 20+ and `tmux`. Binds `127.0.0.1:8787` only.

```bash
cd vibe-daemon
npm install
npm test          # 24 tests incl. a real-tmux reattach wire test
npm start         # http://127.0.0.1:8787 (localhost only)
npm run pair:new  # print a one-time pairing code for a new device
```

Expose it to your phone over the tailnet (one-time, no public port):

```bash
tailscale serve --bg 8787   # https://<machine>.<tailnet>.ts.net → 127.0.0.1:8787
```

Run as a service: see [`vibe-daemon/deploy/`](vibe-daemon/deploy/) (systemd unit
+ install steps).

Useful env: `VIBE_PROJECT_ROOTS` (comma-separated dirs the scanner walks,
default: your home directory), `PORT`, `VIBE_DB`.

## App — run it

Requires the Flutter SDK; building for Android needs the Android SDK + JDK 17.

```bash
cd app
flutter pub get
flutter analyze        # clean
flutter test           # 6 tests (reconnect policy + pairing form)
flutter run            # on a connected device, or:
flutter build apk      # → build/app/outputs/flutter-apk/
```

First launch: enter the daemon URL + a pairing code (`npm run pair:new` on the
server), then pick a project and open a terminal.

## Security

This app exposes a shell over the network — see
[`docs/security.md`](docs/security.md). The daemon never binds beyond localhost;
ingress is `tailscale serve`; every request needs a paired device token; pairing
requires physical server access (the code is printed in the server terminal).
