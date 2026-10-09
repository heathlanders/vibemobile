# ADR 0015 — Desktop client from the same Flutter codebase

**Status:** Accepted (2026-10-04). Phase 0 of the desktop roadmap below.

## Context

The operator prompts from a Windows PC into the Linux box (VS Code, terminals).
They want one desktop app for projects, sessions, prompts, token spend, box
resources and multiple model providers, with the phone app staying in sync.

The daemon is already client-agnostic: every route is bearer-token auth over
`tailscale serve` (ADR 0005), and nothing in it depends on Android. The app had
no `windows/` target and four mobile-only plugins: FCM (`firebase_messaging`),
share intents (`receive_sharing_intent`), on-device speech (`speech_to_text`)
and the camera source of `image_picker`.

## Decision

1. **Same `app/` codebase, new `windows/` target.** Features ship to both
   phone and desktop; the layout adapts to window width. A separate
   Electron/Tauri or web client was rejected because it would duplicate the
   client logic (WS framing, reconnect, providers).
2. **One gate, `core/platform.dart` `isMobile`.** On desktop:
   - FCM is skipped entirely. `PushService.init()` only initializes local
     notifications (Linux/Windows settings), and `registerToken()` is a no-op.
     `notifyPrompt` already raises a local notification for an attached,
     off-screen session's prompt, so the desktop is alerted while the app runs.
     Nothing is delivered while it is closed; that is acceptable because the
     phone still gets FCM.
   - Share-intent listeners are not registered.
   - The mic button is hidden. Attach opens the file dialog directly, with no
     camera option.
3. **Adaptive shell.** When paired and the window is at least 1000 px wide
   (`DesktopShell.breakpoint`), `_Root` shows `DesktopShell`. Its
   NavigationRail (Projects, Live, Multi-chat, Prompts, Search, Settings) swaps
   pages in place instead of pushing routes, and the dashboard hides its
   now-duplicate app-bar actions (`showNavActions: false`). Narrow windows,
   and phones, keep the existing layout.
4. **Pairing is unchanged.** Run `gen-pairing-code` on the box, then `/pair`.
   On desktop the device name defaults to `desktop`, so it can be told apart in
   the device list and revoked separately.

## Consequences

- **Security:** no daemon change and no new ingress. The desktop token lives in
  `flutter_secure_storage`, which uses Windows Credential Manager (DPAPI).
  Revoke it like any other device (`DELETE /devices/:id`).
- **Build:** Flutter can't cross-compile Windows, so build on the PC with
  `flutter build windows`. The box is headless and has no Linux desktop
  toolchain, so desktop UI is verified with widget tests at desktop sizes
  (`test/desktop_shell_test.dart`) and on the PC.
- Desktop notifications have no Allow/Deny buttons. Clicking one opens the
  session, and the permission card is answered there.
- **Desktop input conventions** (`isMobile` gates, build plan 2026-10-06):
  - Chat text: the message list sits in a `SelectionArea` — mouse-drag selects
    across messages, Ctrl+C copies. A bubble's Copy message/Retry/Edit is on
    **right-click** (menu at the cursor); phones keep long-press → action sheet
    (no `SelectionArea` there, it would fight the long-press).
  - Composer **Shift+Tab** cycles the session mode ask → auto → plan over the
    daemon's `available` list (`nextMode`), same `mode` frame as the chip — the
    chip changes only on the daemon echo. Ignored (normal focus traversal) for a
    mirrored CLI session or when fewer than two modes exist. Note it can enter
    Auto-allow without the picker's warning text, as in Claude Code's CLI.
  - Sidebar session tile **right-click** → Open in new split, Close tab (if
    open), Rename, Edit tags, Copy session ID, Kill session (confirm; closes
    its tab). Rename/tags/kill dialogs are shared with the phone's project
    screen (`sessions/presentation/session_actions.dart`).

## Roadmap (each phase gets its own doc and PR)

1. **Cockpit:** project tree, tabbed or split sessions, file and diff pane,
   keyboard shortcuts, drag-drop attach. Client only.
2. **All major models + delegation:** a model registry (prices, context,
   strengths) replaces the hard-coded `isNativeProvider`. Providers via the
   Vercel AI SDK: OpenAI, Google, xAI, Mistral, DeepSeek, Groq, OpenRouter,
   Ollama. Non-Claude agent CLIs (Codex, Gemini CLI, Aider) run as
   server-defined terminal presets, so the client sends a preset id and never a
   command. Task profiles map work types to models, plus a "hand off to…"
   action.
3. **Token/cost dashboard:** a migration runner, a per-turn `usage_events`
   table, `GET /usage` aggregates, and rule-based savings tips.
4. **Prompt library v2:** variables, tags, target model, FTS5 history search,
   and an "improve prompt" action.
5. **System monitor:** a read-only `system.ts` (CPU, RAM, disk, processes,
   GPU, allowlisted systemd units), streamed over WS, with RAM/disk alerts. No
   kill or restart in v1.
