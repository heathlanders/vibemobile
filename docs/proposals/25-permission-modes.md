# 25 — Session modes: Ask / Auto-allow / Plan

**Status:** Built (daemon + client; [claude-ws.md § Modes](../protocols/claude-ws.md#modes-proposal-25),
[spike](../spikes/M7-spike-plan-mode.md), security.md #5). On-device walkthrough pending.

## Problem

The only knob over how Claude behaves was a global "Auto-allow tool permissions"
toggle (proposal 18). The SDK query was hard-wired to `permissionMode: "default"`
and `setPermissionMode()` was never called, so there was no way to say "research
and propose first" (the CLI's shift+tab plan mode) from the phone. Worse, plan
mode could not simply be bolted on: it ends with the model calling `ExitPlanMode`,
which arrives through `canUseTool` — and with auto-allow on (the default) the gate
would approve the plan instantly, so a plan would approve itself.

## Decision

1. **Three modes, one control.** `ask` (every tool call round-trips), `auto`
   (today's default), `plan` (read-only until you approve). A composer chip + `/mode`
   switch it live; the settings toggle becomes "Default mode for new sessions".
2. **Wire:** client `{t:'mode', mode}` → daemon whitelists, maps to the SDK mode,
   calls `Query.setPermissionMode`, persists `sessions.mode`, audits `session.mode`,
   echoes `{t:'mode', mode, available}` (also on every attach). Initial mode via
   `POST /sessions {mode}`. The client never sends mode on attach, so a reconnect
   can't clobber a mid-session Plan. Legacy `auto_allow` frame kept (maps to
   auto/ask, never leaves plan).
3. **ExitPlanMode always round-trips** as an `exit_plan` `user_dialog` (plan text,
   no timeout, replayed on attach, pushed when detached). The phone shows a plan
   card: *Approve · auto-allow*, *Approve · ask each*, *Keep planning* (+ feedback,
   sent as the deny message so the model revises).
4. **Native engine:** `ask`/`auto` only; `available` omits `plan` and the chip hides it.
5. **Mirrored CLI sessions:** no chip — the CLI owns its own mode.

Not exposed on purpose: `bypassPermissions` (redundant with auto, needs
`allowDangerouslySkipPermissions`), `dontAsk`, SDK `auto` (classifier), and
`acceptEdits` — the SDK approves edits without calling `canUseTool`, so those
edits would have no per-call audit row. A follow-up if wanted.

## Security tradeoff (security.md #5)

Plan only narrows what executes. The new risk is the plan→execute transition, which
is why ExitPlanMode is a human decision attributed to a device. Server-side
whitelist means no raw SDK mode is reachable from the wire. Mode persistence means
a reaped/restarted session can't silently loosen from `plan`/`ask` to `auto`.

## Touched

- daemon: `engine.ts` (`SessionMode`, `parseMode`, `EngineSession.setMode`),
  `claude.ts` (`setMode`, `exitPlan`, `permissionMode` from mode), `native.ts`,
  `session-ws.ts`, `sessions.ts`, `db.ts` (`sessions.mode`)
- client: `chat/domain/session_mode.dart`, `chat_session_controller.dart`,
  `chat/presentation/mode_widgets.dart` (`ModeChip`, `showModePicker`,
  `ExitPlanCard`), `chat_screen.dart`, `core/chat_settings.dart`,
  `settings_screen.dart`, `session_api.dart`, `push_note.dart` (plan-ready note)

## Verification

`vibe-daemon/src/mode.test.ts` (fake SDK) and `app/test/session_mode_test.dart`;
real-SDK behavior in the spike. On device: new session in Plan → ask for a
refactor → no writes happen, plan card appears → approve → edits land; reject with
feedback → still planning; background the app mid-plan → "plan ready" notification
→ tap → card; restart the daemon → reattach → mode intact.
