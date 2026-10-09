# Milestones — status

Tracks `PLAN.md §6`. Update the status column as work lands.

| ID | Title                       | Status      | Notes                                            |
|----|-----------------------------|-------------|--------------------------------------------------|
| M0 | Spike (prove the engine)    | Done        | Engine risks + WSS-over-tunnel killed. xterm.dart vs a live PTY proven on-device with M2 (2026-06-10). |
| M1 | Daemon skeleton             | Done        | Auth/pairing, SQLite (auth + projects/sessions), scanner + `GET /projects`, systemd unit, `tailscale serve` ingress (ADR 0005, live since M2). |
| M2 | Terminal tab                | Done        | Verified on-device 2026-06-10: session survived WiFi drop via the app (reattach to live tmux). Daemon 24/24, Flutter analyze-clean + 6/6, APK builds, `tailscale serve` live. |
| M3 | Claude sessions             | Done        | Verified on-device 2026-06-10: New Claude runs a real Claude Code session from the phone. Daemon 33/33, Flutter 11/11. |
| M4 | Dashboard + prompt library  | In progress | Built + tested at code level: prompts CRUD+seed (daemon 40/40); Flutter dashboard grid + session switcher + prompt library (vars, use→session), analyze clean + 18/18, APK builds. Remaining: on-device walkthrough. |
| M5 | Notifications + polish       | Done        | M5a (polish): dark dev theme + toggle, cross-project session search, offline transcript cache. M5b (FCM push + deep links) done 2026-09-27 ([ADR 0013](decisions/0013-push-notifications.md)), CLI-session pushes ([ADR 0014](decisions/0014-cli-session-push-hook.md)). |
| M6 | Hardening                   | In progress | Device mgmt + audit log viewer done (proposal 23). security.md: everything Done except #6 Tailnet ACL and #10 gateway (opt-in). iOS not started. |

## M0 detail

Goal: kill the riskiest unknowns before building anything real.

- [x] **Spike 1 — Agent SDK auth.** SDK reuses `claude` CLI login, no API key.
      → [spikes/M0-spike1-agent-sdk-auth.md](spikes/M0-spike1-agent-sdk-auth.md)
- [x] **Spike 2 — PTY↔WS round-trip.** node-pty bytes + resize over WS proven
      headless. → [spikes/M0-spike2-pty-ws-roundtrip.md](spikes/M0-spike2-pty-ws-roundtrip.md)
- [x] **Cloudflare tunnel carries WSS.** Verified 2026-06-09 via an ephemeral
      `cloudflared --url` quick tunnel → `serve-pty.ts` on 127.0.0.1:8788. A `ws`
      client connected `wss://<id>.trycloudflare.com/pty/test`, sent an opcode-`0`
      keystroke, and got the shell prompt + echoed command + output back —
      bidirectional PTY bytes survive the tunnel. Gotchas: (1) quick tunnel reads
      `~/.cloudflared/config.yml` ingress and ignores `--url` unless given an
      isolated `--config`; (2) point origin at `127.0.0.1`, not `localhost`
      (serve-pty binds IPv4 only). Tunnel + serve-pty torn down after — both are
      unauthenticated, never leave running. (Proof generalizes: WSS round-trips
      through a reverse proxy — now `tailscale serve` per ADR 0005, not a public
      Cloudflare hostname. The `vibe.flipstack.app` plan is superseded.)
- [x] **xterm.dart screen** — Flutter `app/` scaffolded (Riverpod, web_socket_channel,
      dio, xterm, flutter_secure_storage). `TerminalScreen` speaks the PTY↔WS
      protocol (`features/terminal/`). Run end-to-end against a live PTY on-device
      as part of M2 (2026-06-10).

**M0 exit criteria:** `tailscale serve` the daemon → connect a throwaway Flutter
screen running xterm.dart to `wss://<machine>.<tailnet>.ts.net/pty/:id` and see a
live shell.

## M1 detail

Daemon skeleton — auth/persistence/scanner/service. Tunnel hostname is the last
piece (shared with M0's exit).

- [x] **Auth + pairing.** Single-use TTL'd pairing codes (`gen-pairing-code.ts`)
      → opaque bearer token; per-device revoke; audit log. `app.ts` gates every
      route outside `{/health, /pair}`. 7 tests in `auth.test.ts`.
- [x] **SQLite.** `db.ts` — auth tables (devices, pairing_codes, events) +
      `projects` / `sessions` (PLAN §3). WAL + foreign keys. `:memory:` for tests.
- [x] **Project scanner.** `scanner.ts` — walks `VIBE_PROJECT_ROOTS` (default
      `/home/user`), detects type by marker file, reads `git_branch` from
      `.git/HEAD` (no shell-out), upserts by `path`. Authed `GET /projects`
      scans + syncs + returns the catalog. 4 tests in `scanner.test.ts`.
- [x] **systemd unit.** `deploy/vibe-daemon.service` (+ `deploy/README.md`).
      `systemd-analyze verify` clean. Operator installs; not auto-enabled.
- [x] **Ingress via `tailscale serve`** (ADR 0005 — supersedes the Cloudflare
      tunnel; solo use, no domain). Daemon stays `127.0.0.1`-bound;
      `tailscale serve --bg 8787` proxies it onto the tailnet with auto-TLS.
      One-time operator command — see `vibe-daemon/deploy/README.md`. Also
      satisfies M0's exit criterion (reach a live shell from the phone).

**M1 exit criteria:** `systemctl enable --now vibe-daemon`, `tailscale serve --bg
8787`, pair a device, and `GET https://<machine>.<tailnet>.ts.net/projects`
(Bearer) returns the live catalog; unauthenticated → 401.

## M2 detail

The reconnect design (tmux-backed PTY, attach-only WS, REST session lifecycle)
forces a build order — each step depends on the one above. Do them in sequence:

1. **M1 auth + SQLite first.** [x] Bearer-token middleware + `projects`/`sessions`
   tables. Done — `app.ts` auth gate + `db.ts` projects/sessions schema. The REST
   session endpoints spawn real shells, so they must not exist before auth
   (`PLAN.md §2C`). → unblocks everything below.
2. **REST session lifecycle.** [x] `POST/GET/DELETE /sessions`, tmux `-L vibe`
   create-on-POST. Done — `src/sessions.ts` (terminal-only; claude→501 in M3),
   project-path-in-roots validation, status reconcile, 9 tests.
   → [protocols/session-rest.md](protocols/session-rest.md)
3. **Attach-only WS + reattach.** [x] `src/pty-ws.ts` replaces `serve-pty.ts`:
   attach-by-id, `has-session` → attach or `4404`, socket close → **detach not
   kill** (`src/tmux.ts`), server ping/pong heartbeat, resize-on-attach. Proven
   by `src/pty-ws.test.ts` (real ws client + real tmux: attach→type→drop→reattach
   survives; 4404; WS auth reject) + `src/tmux.test.ts` (detach ≠ kill).
   → [protocols/reattach.md](protocols/reattach.md),
   [decisions/0004-tmux-backed-pty.md](decisions/0004-tmux-backed-pty.md)
4. **Client reconnect loop.** [x] Done + verified on-device (2026-06-10: WiFi off
   mid-session → app reattached the live shell). Flutter 3.44.1 on the box;
   `flutter analyze` clean, `flutter test` 6/6, debug APK builds (SDK 36 / JDK 17).
   `terminal_session_controller.dart`: stable id, backoff+jitter, close-code
   policy, resize-after-attach; pairing screen + session picker + `IOWebSocketChannel`
   (bearer header + pingInterval). → [protocols/reattach.md](protocols/reattach.md)

Decided so far: [ADR 0004](decisions/0004-tmux-backed-pty.md) (tmux over raw
node-pty). `serve-pty.ts` is the M0 spike shape and gets **replaced** at step 3,
not extended.

**M2 exit criteria:** open a terminal session, kill the network mid-session
(WiFi→cellular), and watch the same shell resume — scrollback intact, no fresh
shell — over the tailnet (`tailscale serve`, ADR 0005).

## M3 detail

Drive Claude Code from the phone: a chat per project, streamed token-by-token,
with every tool call gated by an allow/deny prompt. → [protocols/claude-ws.md](protocols/claude-ws.md)

- [x] **Daemon engine.** `messages` table; `src/claude.ts` (`ClaudeSession` +
      registry, injectable `queryFn`): multi-turn input, `includePartialMessages`
      deltas, `canUseTool` round-trip (deny on timeout / no client, audited),
      transcript persist + `history` replay, resume via `claude_session_id`,
      pending-permission replay on reattach. `src/session-ws.ts` (`WS /session/:id`,
      JSON, attach-only, 4404, heartbeat, detach-on-close). `sessions.ts` un-stubs
      `kind=claude`. 9 new tests (fake `queryFn`, no spend); 33/33 total.
- [x] **Flutter chat.** `core/reconnect.dart` (shared policy, extracted from M2);
      `features/chat/` (`claude_socket.dart` JSON WS, `chat_session_controller.dart`
      reducer + reconnect, `chat_screen.dart` bubbles/streaming/permission card);
      session picker offers terminal **or** Claude. analyze clean, 11/11.
- [ ] **On-device, real Claude** (~$ + `claude` login): ask Claude to read/run
      something → tokens stream, a tool prompts allow/deny on the phone, deny is
      honored; restart the daemon → resume; mid-turn drop → transcript + pending
      prompt recover.

**M3 exit criteria:** from the phone, hold a Claude conversation that edits/reads
the project, approving tools per-tap, and resume it after a daemon restart.

**Permissions (security.md #5):** `permissionMode:'default'` + `canUseTool` →
phone; deny on timeout/unreachable; never `bypassPermissions`; every decision
audited to `events`.

## M4 detail

Management layer: project grid, session switcher, prompt library.

- [x] **Prompt library (daemon).** `prompts` table (global or project-scoped,
      `{{var}}` body, `vars_json` defaults); seeded on first run with the Karpathy
      guidelines (`db.ts:seedPrompts`, fixed id `seed-karpathy`). CRUD in
      `src/prompts.ts` (`POST/GET/GET:id/PUT/DELETE /prompts`, `?project_id`
      returns globals+project). 7 tests; 40/40 total.
- [x] **Dashboard + switcher + library (Flutter).** `features/dashboard` (project
      grid, live-session count per card); `features/sessions/session_switcher`
      (jump between live sessions); `features/prompts` (list/search, edit, **use**:
      fill `{{vars}}` → pick a live Claude session or "new in project" → opens the
      chat with the filled prompt as the first turn via `ChatScreen.initialMessage`).
      Pure template utils (`extractVars`/`fillTemplate`) unit-tested; analyze
      clean, 18/18, APK builds. (Old `session_picker.dart` replaced by the
      dashboard + `project_sessions_screen.dart`.)
- [ ] **On-device walkthrough:** grid shows projects + live counts; create a
      templated prompt, Use it → fill → "new Claude in <project>" → chat opens and
      sends it; switcher jumps between live sessions.

**M4 exit criteria:** from the phone, browse the project grid, author a `{{var}}`
prompt, fire it into a new Claude session, and jump between live sessions.

## M5 detail (split: M5a polish, M5b notifications)

PLAN M5 = FCM + deep links + theming + session search + offline cache. FCM needs
a Firebase project (user setup), so M5 is split.

### M5a — polish (done, code level)
- [x] **Theming.** `core/theme.dart` (Material 3 dark-default + light, dev-tuned),
      `core/theme_controller.dart` (`themeModeProvider`, persisted via
      `shared_preferences`), toggle in the dashboard app-bar. Replaces the M2
      deep-purple seed.
- [x] **Session search.** `sessionMatches` pure predicate (`sessions/domain`) +
      `session_search_screen.dart` (all sessions across projects, any status);
      dashboard search icon. (Distinct from the live-only switcher.)
- [x] **Offline transcript cache.** `chat/data/transcript_cache.dart`
      (`shared_preferences`, per-session) + `ChatMessage` json; the chat controller
      seeds from cache on open and saves on durable frames, exposing an `offline`
      flag → "showing cached transcript" banner. 8 new tests; flutter 26/26, APK builds.

### M5b — notifications
- [x] **Done (2026-09-27), [ADR 0013](decisions/0013-push-notifications.md).**
      Daemon `push.ts` + `/devices/fcm` + `/sessions/:id/pending|permission|dialog`;
      app `features/notifications` (Allow/Deny + option buttons, tap opens the
      session). Permission gate unchanged (120 s). CLI-session hooks are a follow-up.
- [x] FCM push (firebase-admin on the daemon, `devices.fcm_token` register
      endpoint), triggers on "Claude needs approval" (canUseTool, no client) +
      "session finished" (result), deep-link a tapped banner to the session.
      (Firebase project, `google-services.json` and the service-account key were
      set up for the 2026-09-27 ship.)
- [x] **CLI-session pushes (2026-09-27), [ADR 0014](decisions/0014-cli-session-push-hook.md).**
      A Claude Code `Notification` hook → `hook.sock` (hook.ts) → same FCM path;
      notify-only (tap opens the session, answer in its terminal).

**M5a exit criteria:** dark by default + persistent toggle; search finds sessions
across projects; a chat opens offline showing its cached transcript, refreshing on
reconnect.

## Model-agnostic engine (ADR 0007)

Pick any frontier model per session, "like Claude chat." Keeps the Agent SDK;
routes it (when configured) at a local Anthropic-compat gateway.
See [ADR 0007](decisions/0007-model-agnostic-gateway.md),
[M5 spike](spikes/M5-spike-gateway-model-swap.md), `security.md` #10.

- [x] **Daemon (code + tests).** `sessions.model` column (db.ts); `gateway.ts`
      (`gatewayEnv()` opt-in + `listModels()`); `ClaudeSession` applies `options.model`
      + gateway `env` (claude.ts); `POST /sessions {model}` + `GET /models`
      (sessions.ts); model threaded through session-ws. Covered by
      `gateway.test.ts`, plus new cases in `claude.test.ts` / `sessions.test.ts`
      (84 daemon tests green).
- [x] **Flutter model picker (code).** `GET /models` + `model` on create
      (session_api.dart), `ModelInfo` + `Session.model` (domain), last-used
      persistence (model_prefs.dart), picker sheet on "New Claude"
      (project_sessions_screen.dart). _`flutter analyze` clean (toolchain lives at
      `~/flutter/bin`, not on PATH); APK build still unverified._
- [ ] **Live gateway spike (gate).** `npm run spike:gateway -- <cwd> <model>`
      against a running gateway confirms base-URL mode + the tool loop through a
      non-Claude model. Blocks the ops rollout until green.
- [ ] **Ops rollout.** systemd unit for a `127.0.0.1`-bound gateway
      (LiteLLM/claude-code-router) with `chmod 600` key config; set
      `VIBE_GATEWAY_URL` / `VIBE_GATEWAY_TOKEN` / `VIBE_GATEWAY_MODELS` on the daemon.

**Exit criteria:** with the gateway configured, the phone lists models via
`GET /models`, creating a Claude session on a non-Claude model streams chat + a
tool round-trip over the real WS with the permission gate intact; with no gateway
configured, behaviour is byte-identical to today's real Claude.

## Native multi-provider engine (ADR 0008)

Run non-Claude models **as themselves** (own native tool-calling) via the Vercel AI
SDK, beside the Agent SDK. Same `claude-ws.md` wire → Flutter UI unchanged.
See [ADR 0008](decisions/0008-native-engine.md), [M6 spike](spikes/M6-spike-native-engine.md),
`security.md` #11.

- [x] **Shared core (refactor).** `PermissionGate` extracted from claude.ts
      (permission-gate.ts) → both engines gate + audit identically; `EngineSession`
      interface (engine.ts) implemented by both; `providerFor`/`isNativeProvider`
      routing (gateway.ts). Existing 84 tests green (extraction is behaviour-preserving).
- [x] **Tier 1 — chat.** `NativeSession` (native.ts) over `streamText`; stateless
      resume via transcript replay; cost from token usage; `session-ws` engine branch.
- [x] **Tier 2 — read-only tools.** `read_file`/`list_dir`/`search_files` (native-tools.ts),
      each through the shared gate + `pathInRoots`, pure-JS (no spawn/writes). Dial:
      `VIBE_NATIVE_TIER` (default 2). 92 daemon tests green (native.test.ts +
      native WS integration case).
- [ ] **Tier 3 — write/edit + bash.** Deferred; gates on a security review.
- [ ] **M6 spike (gate).** `OPENAI_API_KEY=… npm run spike:native -- <model>` — live
      native chat + tool loop for a real model.
- [ ] **Ops.** Set `OPENAI_API_KEY` (later `GOOGLE_*`) on the daemon; add the model to
      `VIBE_GATEWAY_MODELS` with `provider:"openai"`.

**Exit criteria:** create a session on an `openai` model → GPT streams chat and drives
its own gated tools over the real WS (permission_request → allow → tool_result); no
key/config → behaviour unchanged (unknown provider routes to Claude).

## Desktop client (ADR 0015)

One Flutter codebase, Windows target beside Android; features shared, layout
adapts. See [ADR 0015](decisions/0015-desktop-client.md) for the full roadmap.

- [x] **Phase 0 — desktop target (code).** `windows/` added; `isMobile` gates FCM,
      share intents, mic, camera; local notifications on Linux/Windows; `DesktopShell`
      rail at ≥1000 px. `flutter test` 92/92 (`desktop_shell_test.dart`). _Windows
      build + live pairing unverified — needs the PC._
- [x] **Phase 1 — workspace (code), [proposal 24](proposals/24-desktop-workspace.md).** Sidebar,
      tabs (kept alive) + split, changes pane, Ctrl+K/Tab/W/\, Enter-to-send, drag-drop
      images. `flutter test` 94/94. _Not yet run on Windows._
- [x] **Phase 2 — models + delegation (code), [ADR 0016](decisions/0016-model-registry-and-agent-presets.md).**
      `providers.ts` (8 providers, `provider:model` routing, live discovery), models file
      (price/context/tags → picker + cost meter), `presets.ts` + `GET /presets` (tmux-typed,
      live-verified), searchable grouped model picker, "Hand off to another model…".
      Daemon 215/215 (Node 18), app 100/100. _Live provider calls need keys on the box;
      per-task profiles deferred._
- [x] **Phase 3 — usage dashboard (code), [ADR 0017](decisions/0017-spend-ledger.md).** `usage_events`
      ledger (per model per turn, both engines), `GET /spend` (allowlisted groups), Usage page
      (tiles, per-day bars, ranked breakdown, saving tips; layout checked at 360 + 900 px).
      Daemon 219/219, app 105/105.
- [x] **Phase 4 — prompt library v2 (code), [ADR 0018](decisions/0018-prompt-library-v2.md).** Past-prompt
      history across sessions (LIKE, deduped), use counts + "most used" sort, "Improve prompt"
      (locked-down one-shot SDK call, live-verified) in the editor and chat menu,
      [prompting guide](prompting-guide.md). Daemon 223/223, app 107/107.
- [x] **Phase 5 — system monitor (code), [ADR 0019](decisions/0019-system-monitor.md).** Read-only
      `GET /system` (CPU, load, mem/swap, disks, GPU, top procs, services; live-verified on the
      box), 60 s monitor → content-free `system_alert` push with cooldown, System page (rail +
      Settings; layout checked at 360 + 900 px). Daemon 227/227, app 111/111.

### Next session — start here (as of 2026-10-06)

All six phase commits are on branch `feat/desktop-target` (PR open against `main`).

**Deploy (not done yet, on purpose):**
- [x] **Restart the daemon.** Done 2026-10-06 (new routes answer 401, not 404). It runs from this checkout
      (`WorkingDirectory=…/vibe-daemon`), so on its next restart (including a
      reboot) it runs whatever branch is checked out. The new `@ai-sdk/*`
      packages are already in `node_modules`. Until it restarts, `/presets`,
      `/spend`, `/system`, `/prompts/history|improve` don't exist, and the new app
      screens show errors for them.
- [x] **Windows build on the PC.** Built, paired and installed 2026-10-06 (no
      code fixes needed). Clone to `%USERPROFILE%\vibemobile` (not an admin shell,
      which starts in `system32`), `flutter run -d windows` first, then
      `flutter build windows --release` and copy the whole `Release\` folder to
      `C:\Program Files\VibeMobile` from an admin PowerShell.
      - **Updating:** the install is `C:\Program Files\VibeMobile\Release`. Close the
        app fully, then from an admin PowerShell:
        `robocopy <repo>\app\build\windows\x64\runner\Release "C:\Program Files\VibeMobile\Release" /MIR`
        (exit codes 0–7 = success). Pairing survives; the token lives in the user profile.
      - **VS 2022 must be current (17.14+).** An older one fails to link Firebase's
        prebuilt C++ SDK: `LNK2019 unresolved external symbol __std_remove_8` /
        `__std_find_first_of_trivial_pos_1`. Update in VS Installer, then `flutter clean`.
      - `LNK4099 PDB not found` warnings are harmless.
      - Still to check on the PC: the Workspace sidebar auto-refresh, and a `vc`
        question answered from the desktop.
- [ ] **Provider keys** in `~/.config/vibe-daemon.env` (`OPENAI_API_KEY`,
      `GOOGLE_GENERATIVE_AI_API_KEY`, `XAI_API_KEY`, `MISTRAL_API_KEY`,
      `DEEPSEEK_API_KEY`, `GROQ_API_KEY`, `OPENROUTER_API_KEY`, `VIBE_OLLAMA_URL`),
      and optionally `~/.config/vibe-daemon/models.json` for price and tags
      ([ADR 0016](decisions/0016-model-registry-and-agent-presets.md)). Then run a
      live native turn per provider, plus a hand-off to a non-Claude model.
- [ ] **Box health:** swap was 100% used and `/` 92% full on 2026-10-05. The
      monitor will push about this as soon as it's running.

**Gotchas:**
- Run daemon tests with `/usr/bin/node node_modules/tsx/dist/cli.mjs --test src/*.test.ts`.
  Node 18 matches the `better-sqlite3` build, while the shell's nvm Node 20
  fails, so a plain `npm test` breaks. Don't `npm rebuild`.
- To render a widget for a layout check:
  `VIBE_W=360 VIBE_RENDER=<png> flutter test --update-goldens test/spend_test.dart`
  (`system_test.dart` works the same way).

**Planned next (both clients, from the same codebase):**
- [x] **AskUserQuestion in mirrored `vc` sessions** — done 2026-10-06, see the
      ADR 0012 addendum (key map + live check). Daemon 229/229, controller tests pass. ([ADR 0012](decisions/0012-external-session-mirror.md)).
      Before: `external.ts` `apply()` forwards the CLI's `AskUserQuestion` as a plain
      `tool_use` frame, so the app shows a generic tool card, not the question,
      and the answer can only be given in the Terminal view. Plan:
      1. Client: render a mirrored `tool_use` named `AskUserQuestion` (with no
         `tool_result` yet) using the existing question card from `chat_screen.dart`.
      2. Repliable (`vc`) sessions — **decided 2026-10-06: answer from the app**
         (not read-only): tapping an option sends a new
         `{t:"dialog_answer"}`-style frame; the daemon maps it to TUI keystrokes
         (`send-keys`) on the resolved `vc-` pane, same resolution and audit as
         `external.input` (security.md #16). The keys are not keystroke-stable
         across CLI versions, so **spike first**: record the TUI's key handling
         for single, multi-select and "Other" answers.
      3. Non-`vc` mirrors, or if the spike fails: show the question read-only
         with an "Answer in Terminal" button.
      → verify against a live `vc` session (phone and desktop), then add an
      addendum to ADR 0012 and update the "Pending permission prompts" consequence.
- [x] **Session list sync across devices** — code done 2026-10-06: expanded
      sidebar lists refetch every 15 s while the Workspace is on screen (old list
      stays up meanwhile) and everything refetches on window focus
      (`AppLifecycleListener.onResume`). Still to verify on the Windows build.
      Original note: Sessions all live in the daemon, so
      a session started on the phone already exists for the desktop. But the
      Workspace sidebar (`workspace_screen.dart`) and dashboard only refetch on
      manual Refresh, so a new session doesn't appear until then. Plan: refetch
      when the desktop window regains focus and on a light poll (about 15 s)
      while the sidebar is visible. Push via a server event stream only if
      polling proves too slow. Same fix covers CLI sessions found by discovery.
      → verify: start a chat on the phone and see it in the desktop sidebar
      without clicking Refresh.

- [x] **Plan-usage meter follow-ups** ([ADR 0020](decisions/0020-plan-usage-sidebar.md)) —
      done 2026-10-06: live sessions' `rate_limit_event` feeds the usage cache,
      and a content-free `usage_reset` push fires once per window when the 5-hour
      window is <30 min from reset and <50 % used, or the weekly All-models
      window is <12 h from reset and <50 % used. Needs a daemon restart to go live.

**Deferred / ideas:**
- [x] Per-task model profiles (plan, implement, review, quick → model) and
      auto-suggesting a model from the prompt — done 2026-10-06
      ([ADR 0016](decisions/0016-model-registry-and-agent-presets.md)).
- [x] A CLAUDE.md-size savings tip, and per-session token detail in the chat
      header — done 2026-10-06 ([ADR 0017](decisions/0017-spend-ledger.md)).
      Needs a daemon restart.
- [ ] System actions (restart a unit, clean a cache). Needs an ADR, an
      allowlist and an audit trail.
- [ ] FTS5 for prompt history, once it has tens of thousands of rows.
- [x] Workspace tab labels don't follow auto-title renames — done 2026-10-06:
      `ChatScreen.onTitle` → workspace live title map
      ([proposal 24](proposals/24-desktop-workspace.md)).
- [x] The same session open in Multi-chat and in a tab fought over the socket —
      done 2026-10-06: app-wide ref-counted controller pool (one socket per
      session per device) + daemon `detach(ws)` ignores superseded sockets
      ([proposal 19](proposals/19-multi-chat-grid.md)). Needs a daemon restart.
- [x] The phone dashboard's app bar has 6 icons, which is crowded under 360 dp —
      done 2026-10-06: under 360 dp only Search + Prompt library stay as icons;
      Live sessions, Multi-chat, Usage and Settings move to a "More" menu.
      Wider screens unchanged.
- [ ] Desktop has no push while closed. Consider a tray/background mode later.

## UX track — "alive, not louder"

Client-side UX programme kicked off because the app read as boring: capable but
motionless. Aesthetic north star (DESIGN.md §1) is unchanged; the work adds motion,
loading/empty states, and composer power. Phases after 1 are planned, not started.

- [x] **Phase 1 — motion & polish foundation.** `Motion` tokens + `SkeletonBox`/
      `SkeletonList`/`FadeSlideIn`/`StreamingCursor`/`EmptyState`/`sharedAxisRoute`
      in `core/`; chat cursor/gates/banner/FAB animated; dashboard skeleton grid +
      staggered cards; all 14 push sites on the new route. Zero new pub deps.
      `flutter analyze` clean, `flutter test` 49/49 (4 new in `motion_test.dart`).
      → [proposal 21](proposals/21-motion-polish.md), DESIGN.md §9.
      _Pending on-device pass: cursor/banner/gates in dark + light; hero tile→chat
      deferred to that session._
- [x] **Phase 2a — slash commands + prompt insert.** `detectSlash` (pure) +
      `ComposerSuggestions` inline above the composer; `/prompt` (library filter
      + `{{var}}` fill sheet reusing `extractVars`/`fillTemplate`), `/files`,
      `/copy`, `/stop`. No wire change. `flutter analyze` clean, `flutter test`
      59/59 (10 new). → [proposal 22](proposals/22-composer-commands.md).
      _Pending on-device pass._
- [x] **Phase 2b — `@file` mentions.** `GET /sessions/:id/tree` (project-tree.ts):
      session-scoped, names-only, `pathInRoots`, no shell-out, symlinks skipped,
      dotdirs/dep dirs excluded, capped + `truncated`, audited, 30/min. Client:
      `detectMention` + `project_tree_api.dart` → suggestion list; the daemon never
      resolves a mention. → [ADR 0010](decisions/0010-session-tree-read-surface.md),
      `security.md` #13. Daemon 139/139, client 66/66, analyze clean.
      _Pending on-device pass._
- [x] **Phase 3 — diff preview on permission cards + swipe approve.** Diff
      rendering lifted to `diff-preview.ts` (shared by the gate + the file
      viewer); `permission_request.diffPreview` built from the *same input object*
      resolved as `updatedInput` (render == execution, asserted by identity);
      client renders a collapsed diff via the shared `DiffLine` and adds
      `Dismissible` swipe (0.55 threshold, confirm on `Bash`/`Write`, buttons
      kept, audit path unchanged). → [proposal 02](proposals/02-diff-viewer.md),
      `claude-ws.md`, `security.md` #5. Daemon 148/148, client 68/68.
      _Pending on-device pass with auto-allow OFF._
- [x] **Phase 4a — cockpit surfacing.** `Project.lastActive` + `relativeAge` (grid
      sorts by it), `Session.totalCostUsd` + `costLabel` in session lists. Both
      were already on the wire and dropped by the Dart models. Zero daemon change.
- [x] **Phase 4b — audit log + device management.** `GET /events`
      (read-only, ≤200, keyset `before=`, `kind=` prefix, `idx_events_ts`, not
      self-logged) + `current` flag on `GET /devices`; client
      `devices_screen.dart` (revoke, signs out when revoking itself) and
      `audit_log_screen.dart` (kind chips). → [proposal 23](proposals/23-project-cockpit.md),
      `security.md` #14 (+ #4 now revocable from the app). Daemon 155/155,
      client 74/74. _Pending on-device pass._
- [x] **Phase 4c (part 1) — read-only git status.** `git.ts`:
      `GET /projects/:id/git-status`, fixed argv `execFile` (no client-supplied
      argument at all), `pathInRoots`, 5 s timeout, 1 MiB cap, ≤200 files +
      `truncated`; non-repo ⇒ `repo:false` and the client hides the strip.
      Client: `git_api.dart` + status strip on the project screen (tap → changed
      paths). → [ADR 0011](decisions/0011-git-surface.md), `security.md` #15.
      Daemon 166/166, client 78/78.
- [~] **Phase 4c (part 2) — git writes.** Commit/stage/branch **built**; push
      still **not built** (needs its own ADR: opt-in `VIBE_GIT_PUSH=1`,
      server-chosen + pinned remote, confirm sheet). See "Harness gap work" below.
- [x] **Phase 5 — FCM.** Shipped as M5b (turn finished + approvals, ADR 0013).
      Relaxing the 120 s permission hold remains a separate ADR, not started.

## Harness gap work — worktrees, rewind, git writes (ADRs 0022-0024, 2026-10-07)

From the gap analysis against mainstream coding harnesses. Daemon 358/358, client
198/198. All four verified against the real Agent SDK (not only fakes).

- [x] **P0 — M8 spike + ADRs.** [M8 spike](spikes/M8-spike-checkpoint-rewind.md):
      `rewindFiles(u)` undoes `u`'s edits and everything after; Bash edits untracked;
      works in a worktree cwd and across resume.
- [x] **P1 — git hardening.** `git-run.ts` `gitRun`: hooks/`core.fsmonitor`/
      `sshCommand`/credential helper neutralised, `GIT_*` env stripped
      ([ADR 0024](decisions/0024-git-write-surface.md), `security.md` #15).
- [x] **P2 — file rewind.** `POST /sessions/:id/rewind`, "Rewind files to here" on a
      user bubble ([ADR 0023](decisions/0023-checkpoint-rewind.md), #24).
- [x] **P3 — worktree per session.** `worktree:true`, `.vibe-worktrees/<id>`,
      isolated Auto/rewind scope, remove-only-if-nothing-lost
      ([ADR 0022](decisions/0022-worktree-sessions.md), #25).
- [x] **P4 — stage / commit / branch, no push.** "Commit…" sheet; secrets locked out
      ([ADR 0024](decisions/0024-git-write-surface.md), #26).
- [ ] _Pending on-device pass_ for P2-P4 (rewind sheet, isolated Claude, commit sheet).
- [ ] **Not done / follow-ups:** git **push** (own ADR); conversation "branch from
      here" (`forkSession`); the changed-files list still shows files after a rewind
      (it is rebuilt from tool rows); rewind covers only turns sent after P2 (older
      rows have no checkpoint uuid); `projects.ts` `gitInit` not yet on `gitRun`;
      (the "Commit…" button now also shows when the session made no tracked edits).

### Gap-analysis follow-on (2026-10-07, after P4)

- [x] **Markdown in assistant messages** — [proposal 35](proposals/35-chat-markdown.md).
- [x] **Thinking blocks** — [proposal 36](proposals/36-thinking-blocks.md), [M9 spike](spikes/M9-spike-thinking.md).
- [x] **Switch model mid-session** — [proposal 37](proposals/37-live-model-switch.md); fixed a latent
      session-killing crash on string-content SDK messages found while verifying it.
- [x] **Mobile terminal key row** — [proposal 38](proposals/38-terminal-key-row.md).
- [x] **Session rules + storage settings, daemon-data footprint, disk limits** — [ADR 0026](decisions/0026-session-rules-and-settings.md),
      [M10 spike](spikes/M10-spike-session-rules.md). Needs a daemon restart to take effect.
- [x] **Reasoning effort control** — [proposal 39](proposals/39-effort-control.md), [M11 spike](spikes/M11-spike-effort.md).
- [x] **Context meter + manual compaction** — [proposal 40](proposals/40-context-meter-compact.md), [M12 spike](spikes/M12-spike-context-compact.md).
- [x] **Skills + slash commands in the composer** — [proposal 41](proposals/41-slash-commands.md), [M13 spike](spikes/M13-spike-slash-commands.md).
- [x] **Branch a conversation** — [proposal 42](proposals/42-branch-conversation.md), [M14 spike](spikes/M14-spike-fork.md).
- [x] **Tools & integrations (MCP view)** — [proposal 43](proposals/43-mcp-view.md), [M15 spike](spikes/M15-spike-mcp.md). Hooks deliberately not built (needs its own ADR).
- [x] **Scheduled tasks** — [ADR 0027](decisions/0027-scheduled-prompts.md). Settings → Server → Scheduled tasks. Needs a daemon restart (it creates the `schedules` table and starts the tick).
- [x] **Pull request & CI status (read-only)** — [proposal 45](proposals/45-pr-ci-status.md).
- [x] **Read-only file browser** — [proposal 46](proposals/46-file-browser.md), `security.md` #31.
- **Gap list — closed 2026-10-07.** Everything on it that is buildable *and* safe is built (items above,
  proposals 27-28 and 35-46, ADRs 0022-0027). What was **deliberately not built**, and why:
  - **Hooks UI** — no safe way to list them (they are shell commands in settings files, possibly with
    secrets) and editing them from a phone is remote-code-execution configuration. Needs its own ADR
    ([M15 spike](spikes/M15-spike-mcp.md)).
  - **Git push / PR creation** — needs the opt-in env, a server-chosen pinned remote and a confirm
    sheet (ADR 0024 §4). PR/CI *status* is read-only and built (proposal 45).
  - **Test / lint runner** — would be daemon-run project commands with their output parsed; the PTY
    terminal and a chat prompt ("run the tests") already cover it without a new execution surface.
  - **Repo map / semantic code index** — large, and Claude's own Grep/Glob/Read already answer it.
  - **Native-engine write / edit / bash tools (Tier 3)** — still waiting on the security review noted
    in the native-engine section.
  - **Project rename / delete** — the scanner re-adds a project from disk and overwrites its name on
    every rescan, so either would silently revert; it needs an ignore list first.
  - **Worktree / native forks, in-app OAuth for connectors, cron expressions, per-run digests** — noted
    as out of scope in their proposals/ADRs.
- **Restart needed.** The daemon was started before most of this landed: `systemctl --user restart vibe-daemon`
  (ends every live chat; they resume). It creates the `schedules` and `settings` tables and starts the scheduler.
- [ ] Still _pending on-device_: all of the above plus P2-P4. Not started from the gap list:
      effort control, conversation fork, Claude Code slash commands/skills/MCP/hooks UI,
      context meter + compaction, scheduled tasks, PR/CI integration.
- Process note: a partial `git apply --unidiff-zero` staging of `claude.ts` committed a corrupt
  file in `2d01ebf` (fixed forward in `a2d5d6d`). Partial staging now builds the blob from file
  contents and is verified by running the tests on a clean checkout of the index.
