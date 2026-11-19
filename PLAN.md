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
- **Project scanner:** lists project dirs under the home directory, detects type
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

**Multi-device chat ([proposal 58](docs/proposals/58-multi-device-chat.md)).**
- [x] Chat sessions fan out to every attached client; first permission/dialog answer wins
- [x] `stop()` closes attached sockets (1012 retry, 4404 stop)
- [x] On-device check: phone + Windows app on one chat (1.0.31)

**Project files API + transfer ([proposal 59](docs/proposals/59-project-files-transfer.md)).**
- [x] ADR 0030 project-file writes + `security.md` items + docs-map row
- [x] Daemon `project-files.ts`: list / read text (sha) / write text (409 on stale sha), project + session scoped, tests
- [x] Daemon raw download / upload (encapsulated plugin, caps, `wx` unless overwrite), tests; `reviewer` pass
- [x] App: project Files screen, Download, Upload here (+ desktop drag-drop), progress, overwrite prompt
- [ ] On-device check: >5 MiB binary round trip on phone and Windows

**Code editor ([proposal 60](docs/proposals/60-code-editor.md)).**
- [ ] Phase 1: re_editor core — 2 MiB perf check, highlight + themes, folding, find/replace, save + 409 dialog, Markdown/JSON preview, desktop tab, all entry points
- [ ] Phase 2: format (Prettier, dart format) + lint (ESLint → Error Lens gutter + inline), exec allowlist; `reviewer` pass
- [ ] Phase 3: git change gutter, blame hint, rainbow brackets, indent guides
- [ ] On-device check on phone and Windows per proposal 60

**Improve from chat ([proposal 63](docs/proposals/63-improve-from-chat.md)).**
- [x] Chat Improve opens a sheet: type, or pick a sent message or a Claude reply; Improve / Go deeper
- [x] Composer keyboard refocus after Improve; widget tests
- [x] On-device check: phone keyboard comes back; improve a Claude reply (1.0.35)

**Idea Scout ([proposal 66](docs/proposals/66-idea-scout.md)).**
- [x] `signals.py` scanner + skill pipeline; SDK session loads the skill and `researcher`
- [ ] First full run: report reviewed, spend per run recorded
- [ ] Monthly Schedule from the app; "Run now" ends with the done push

### Review 2026-11-19 — fix the base before new features

Work these top to bottom, one box per session. Each box = one PR with its tests. Details,
file pointers and acceptance tests are in the linked proposal; tick the box and fill the
proposal's *What shipped* when merged.

**Stop the bleeding ([68](docs/proposals/68-daemon-auth-hardening.md), [69](docs/proposals/69-daemon-reliability-ops.md), [70](docs/proposals/70-app-resilience.md)).**
- [x] 69 R1: PTY frame guard + process-level error handlers
- [x] 68 A1: close a device's sockets on revoke (4401)
- [x] 68 A4: global `/pair` attempt cap
- [ ] 68 A4 ops (owner): confirm nothing uses the raw TCP forward, then remove it (private ops note)
- [x] 70 C1: queue sends while disconnected
- [x] 70 C2: auth failure from close code / REST probe, not text match
- [x] 70 C3: shared Dio with timeouts
- [x] 70 C4: confirm before ending a session

**CI ([72](docs/proposals/72-ci-and-release-hygiene.md)).**
- [x] 72 Q1: `ci.yml` runs analyze + tests for app and daemon
- [ ] 72 Q1 (owner): make the `app` and `daemon` checks required on main
- [x] 72 Q2: daemon `tsconfig.json` + `typecheck`, clean, in CI
- [x] 72 Q4: `release.sh` builds before tagging; `--rollback`
- [x] 72 Q3: zod schemas on incoming WS frames
- [x] 72 Q5: widget tests for pairing, updater, terminal
- [ ] 72 Q6: license decision (owner)

**Daemon reliability ([69](docs/proposals/69-daemon-reliability-ops.md)).**
- [x] 69 R5: logger, error handler, graceful stop, real `/health`
- [x] 69 R2: reaper skips running turns and pending dialogs
- [x] 69 R3: SDK loop crash removes the session (test first)
- [x] 69 R8 + R7: `messages` index, retention, vacuum, nightly backup (`tool_use_id` deferred)
- [ ] 69 R7 ops (owner): set `VIBE_BACKUP_DIR` to a dedicated dir under the backups disk in the live unit
- [x] 69 R6: audit log records command text; `security.md` corrected
- [x] 69 R4: spike — does tmux survive a daemon restart? fix if not
- [ ] 69 R11: commit the real unit with memory caps; Node 20+ (do last in a session)
- [ ] 69 R10: backpressure on PTY and chat sockets
- [ ] 69 R9: Bash ask-list in Auto mode; `reviewer` pass
- [ ] 69 R12: spikes out of `src/`

**Auth lifecycle ([68](docs/proposals/68-daemon-auth-hardening.md)).**
- [ ] 68 A3: ADR + box-side confirmation for pair-code mint and revoking another device; `reviewer` pass
- [ ] 68 A2: 60-day idle token expiry
- [ ] 68 A5–A8: name cap, file-edits cap + secret check, symlink re-check, DB mode 600

**App polish and client security ([70](docs/proposals/70-app-resilience.md), [71](docs/proposals/71-client-security.md)).**
- [ ] 70 C5 + C6: draft persistence; newline on phone
- [ ] 70 C9: bad frame skipped, not thrown
- [ ] 70 C7: memoize + throttle streaming rebuilds (measure before/after)
- [ ] 70 C8: desktop minimize keeps sockets (repro first)
- [ ] 70 C10 + C11: readable errors, Retry now, full tool output
- [ ] 71 S1: signed update manifest (two-release rollout); `reviewer` pass
- [ ] 71 S2: no Android backup; transcript cache in private files, pruned
- [ ] 71 S4: https-only pairing
- [ ] 71 S3: optional app lock

**On-device verification sweep.** Built but never checked on a device. Per row: test on the
phone (and Windows where it applies), fix what breaks, set the proposal and its README row to
`shipped` or back to `building` with the defect named.
- [ ] Chat rendering: 32 status line, 33 images, 34 links, 35 markdown, 36 thinking, 47 paste collapse, 48 file links, 57 timestamps
- [ ] Session controls: 25 modes, 37 model switch, 39 effort, 40 context/compact, 41 slash commands, 42 branch, 43 MCP
- [ ] Files and git: 45 PR/CI status, 46 file browser, 59 >5 MiB binary round trip
- [ ] Terminal: 38 key row
- [ ] Notes and prompts: 31 notes, 56 inbox batch, 61 rule packs
- [ ] Desktop: 49 non-maximized window, 55 mouse back/forward
- [ ] Swarm and limits: 65 tasks + leases, 67 continue after limit (real limit hit)
- [ ] Fix status drift in `docs/proposals/README.md` (59, 67; only vocabulary statuses)

**After the base is fixed:** pick from [73](docs/proposals/73-post-review-direction.md). Code
editor phases (proposal 60) wait until then.

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
