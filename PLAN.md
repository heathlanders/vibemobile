# VibeMobile — Plan

Mobile control plane for managing software projects + Claude Code sessions on a
home Linux server, from an Android phone. Built by/for a Flutter developer.

## 1. Goal

A "fully fledged" Android app to:
- See a **dashboard** of all projects on the home server (my-project,
  construction-platform, railroad-saas, …).
- Run **multiple Claude Code sessions per project** with a native mobile chat UI.
- Drop into a **raw terminal** per project for true "as if at my PC" console work.
- Manage a **prompt library** (templates/snippets) and reuse prompts across projects.
- Get **push notifications** when a session needs input or finishes.
- (Desktop track) The same app on the Windows PC: workspace, any model, token spend, box health.

## 2. Architecture (3 parts)

```
┌─────────────────┐      Tailscale (tailnet, TLS, no open ports)     ┌──────────────────────────┐
│  Android app    │  ───────────  WSS + HTTPS  ───────────────────▶  │  Home Linux server       │
│  (Flutter)      │                                                   │  vibe-daemon (Node/TS)   │
│                 │  ◀── stream: chat events, terminal bytes ──────   │                          │
│  - Dashboard    │                                                   │  ├─ Session manager      │
│  - Chat UI      │                                                   │  ├─ Claude engine (SDK)  │
│  - Terminal     │                                                   │  ├─ PTY engine (node-pty)│
│  - Prompt lib   │                                                   │  ├─ Project scanner      │
└─────────────────┘                                                   │  └─ Auth + SQLite        │
                                                                       └──────────────────────────┘
```

### A. Client — Flutter (Android first, iOS later)
- State mgmt: Riverpod (matches your existing my-project pattern).
- Networking: `web_socket_channel` for streams, `dio` for REST.
- Terminal rendering: `xterm.dart` (full ANSI terminal widget).
- Secure token storage: `flutter_secure_storage`.
- Push: Firebase Cloud Messaging (FCM).

### B. Server daemon — `vibe-daemon` (Node 20 + TypeScript)
- HTTP/WS framework: **Fastify** + `@fastify/websocket`.
- **Claude engine:** `@anthropic-ai/claude-agent-sdk` (TS). Spawns/streams Claude
  Code sessions headless (`stream-json` under the hood). One Claude session = one
  resumable session id, mapped to a project cwd.
- **PTY engine:** `node-pty`. One pseudo-terminal per terminal tab, optionally
  inside `tmux` so sessions survive daemon restarts / reconnects.
- **Project scanner:** lists project dirs under `/home/user`, detects type
  (Flutter = pubspec.yaml, Laravel = artisan/composer.json, Node = package.json),
  git status, last activity.
- **Persistence:** SQLite (`better-sqlite3`) — projects, sessions, prompt library,
  device tokens, audit log.
- **Process model:** systemd service `vibe-daemon.service`, runs as `boss`.

### C. Transport / security
- **Transport: Tailscale** (ADR 0005, supersedes the original Cloudflare Tunnel).
  Solo use — the box and phone share a tailnet. Daemon stays `127.0.0.1`-bound;
  `tailscale serve --bg 8787` proxies it onto the tailnet with auto-TLS at
  `https://<machine>.<tailnet>.ts.net`. No public endpoint, no domain.
- **Auth:** device pairing flow. First connect = one-time pairing code shown in
  terminal on server → phone exchanges for a long-lived device token (stored in
  secure storage). All WS/HTTP requires bearer token.
- Network boundary = the **tailnet** (Tailscale ACL limits to the owner's
  devices); bearer token is the second, app-level layer.
- Daemon binds **localhost only** — never directly exposed; `tailscale serve` is
  the only door.

## 3. Core data model (SQLite)

- `projects` — id, path, name, type, git_branch, last_active.
- `sessions` — id, project_id, kind(`claude`|`terminal`), claude_session_id,
  title, status, created_at.
- `messages` — id, session_id, role, content, tool_json, ts. (Claude transcript cache.)
- `prompts` — id, title, body, tags, project_id(nullable=global), vars_json.
  - **Ship seeded:** the 4 Karpathy behavioral guidelines (see CLAUDE.md) are a
    default global prompt/skill on first run — the canonical cross-project prompt
    the library exists to manage. Same content governs how we *build* VibeMobile.
- `devices` — id, name, token_hash, paired_at, last_seen, fcm_token.
- `events` — audit log of every command/prompt run (security + history).

## 4. Key flows

**Dashboard load:** app → `GET /projects` → scanner returns list w/ status badges
(running sessions count, git dirty, type icon).

**Open Claude session:** app → `WS /session/:id` → daemon attaches Agent SDK
stream → forwards events (assistant text, tool_use, tool_result, permission
requests) as JSON → app renders chat. Tap-to-approve maps to SDK permission reply.

**New prompt from library:** app picks template → fills `{{vars}}` → sends as
user turn into chosen session (any project). Same prompt reusable across projects.

**Terminal tab:** app → `WS /pty/:id` → daemon pipes node-pty/tmux bytes both
ways → `xterm.dart` renders. Resize events forwarded.

**Notification:** session emits "needs permission" or "completed" → daemon →
FCM → phone banner → tap deep-links to that session.

## 5. Security checklist (non-negotiable, you're exposing a shell)

- [x] Daemon localhost-bind only; `tailscale serve` = sole ingress (ADR 0005).
- [x] Bearer token on every request; reject unpaired devices.
- [x] Pairing requires physical server access (code printed in server terminal).
- [x] Per-device revoke (lost phone → kill token).
- [x] Rate limit + audit log every executed command.
- [ ] Tailnet ACL limits which devices can reach the daemon.
- [x] Scope command execution to project dirs where feasible.

> Live status of these items is tracked in `docs/security.md`.

## 6. Milestones

**M0 — Spike (prove the engine).** node-pty echo over WS → xterm.dart in a
throwaway Flutter screen. Confirm WSS carries over the tailnet (`tailscale
serve`, ADR 0005). Drive one Claude
Agent SDK session headless from a CLI script, print streamed events. *Goal: kill
the riskiest unknowns first.*

**M1 — Daemon skeleton.** Fastify + WS, SQLite schema, project scanner, systemd
unit, `tailscale serve` ingress (ADR 0005), pairing/auth.

**M2 — Terminal tab.** Full node-pty(+tmux) ↔ xterm.dart, resize, reconnect.
This alone = usable remote-PC-in-pocket.

**M3 — Claude sessions.** Agent SDK integration, native chat UI, multi-session
per project, permission approve/deny, transcript persistence + resume.

**M4 — Dashboard + prompt library.** Project grid w/ status, session switcher,
prompt CRUD + variables + cross-project reuse.

**M5 — Notifications + polish.** FCM, deep links, theming (port your app_theme),
session search, offline transcript cache.

**M6 — Hardening.** Security pass, device mgmt screen, audit log viewer, iOS build.

**Desktop track (2026-10, [ADR 0015](docs/decisions/0015-desktop-client.md)).** The
same Flutter app, built for Windows: a workspace with tabs and split view, every
major model provider plus agent CLI presets and hand-off, a token/cost
dashboard, prompt history and "Improve prompt", a read-only system monitor, and
an always-on Max-plan usage meter with a "use it before it resets" push
([ADR 0020](docs/decisions/0020-plan-usage-sidebar.md)).
Status and next steps are in `docs/milestones.md` → "Desktop client".

## 7. Open questions / risks

- **Agent SDK auth:** confirm SDK uses your existing `claude` CLI login/credentials
  vs. needing an API key. (Verify in M0 — changes cost model.)
- **TUI parity gaps:** some interactive Claude features (slash-command pickers)
  render differently in headless; map them in chat UI or fall back to terminal tab.
- **Node 18 → 20:** still open (ops). The systemd unit runs `/usr/bin/node`
  v18.20.8, while a terminal's nvm default is v20. The latest SDK runs fine on 18.
  The real hazard is running `npm install` in `vibe-daemon` from a v20 shell:
  native modules get rebuilt for the wrong ABI and the daemon fails on restart.
  Server health → Diagnostics flags the drift (proposal 29).
- ~~**tmux dependency:** decide tmux-backed PTY (survives restart) vs. raw node-pty.~~
  Decided: tmux-backed — see `docs/decisions/0004-tmux-backed-pty.md`.
- **Multi-device sync:** if you use 2 phones, sessions are server-side so it's fine,
  but UI state sync is future work.

## 8. Existing prior art to study (M0 research)

- Conductor / Claude Code mobile wrappers, `claude-code-webui`, Happy Coder app,
  vibetunnel, ttyd + xterm patterns. Borrow transport/UX ideas, not code.
