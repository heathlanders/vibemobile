# 18 — Auto-allow tool permissions + no AskUserQuestion timeout

**Status:** Done (landed in [claude-ws.md](../protocols/claude-ws.md#permissions-securitymd--highest-scrutiny))

> Superseded in part by [proposal 25](25-permission-modes.md): auto-allow is now
> the `auto` session mode; the global settings toggle became "Default mode for new
> sessions", and the app no longer sends `auto_allow` (the frame still works).

## Problem

Every Claude tool call (Read, Write, Bash, …) round-trips a `permission_request`
to the phone and blocks the turn. With the phone locked or the socket dropped,
the daemon denies after 120 s — development pauses on every approval. Separately,
AskUserQuestion shared the same 120 s timeout, so an unanswered question was
silently cancelled ("user did not answer") even though the user just hadn't
looked at the phone yet.

## Decision

1. **Auto-allow tool permissions, daemon-side, default ON.**
   - `ClaudeSession.autoAllow = true` by default — `canUseTool` resolves
     `{behavior:'allow', updatedInput}` immediately, audited as
     `permission.auto_allow`. Works even with no client attached (that's the
     point: unattended turns don't stall).
   - New client→server frame `{t:'auto_allow', on:bool}` (session-ws.ts) toggles
     it per session. The phone persists a settings toggle ("Auto-allow tool
     permissions", SharedPreferences, default on) and sends it on every attach
     and on change. Turning it ON flushes any pending `permission_request`.
   - With auto-allow off, the previous flow is unchanged (prompt on phone,
     120 s timeout → deny, replay on reattach).

2. **AskUserQuestion never times out.** The `user_dialog` waits indefinitely for
   the user; it resolves only on a client answer/cancel or session `stop()`
   (cancel = allow with original input, as before). Replay on reattach already
   covered the roam case. Auto-allow does NOT apply to AskUserQuestion — it
   always reaches the phone.

Daemon-side (not client-side) auto-allow was chosen deliberately: a client-side
auto-responder would still deny whenever the app was closed, which is exactly
the pause this removes.

## Security tradeoff (security.md #5)

With auto-allow on, anything Claude decides to run executes on the box without a
human tap. Compensating controls: the tailnet + bearer transport boundary, the
per-decision audit log (`permission.auto_allow` rows), and the toggle itself.
`bypassPermissions` is still never used — the gate stays wired, only its default
answer changed.

## Touched

- `vibe-daemon/src/claude.ts` — `autoAllow` flag, `setAutoAllow()`, no
  AskUserQuestion timeout
- `vibe-daemon/src/session-ws.ts` — `auto_allow` frame
- `app/lib/core/chat_settings.dart` — persisted toggle (default on)
- `app/lib/features/chat/…` — socket frame, controller sync on connect/change
- `app/lib/features/settings/presentation/settings_screen.dart` — toggle UI
- Tests: `claude.test.ts` (3 new), `session-ws.test.ts`
