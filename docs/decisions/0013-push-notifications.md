# ADR 0013 — Push notifications for approvals, questions and finished turns

**Status:** Accepted (2026-09-27). Implements PLAN §4 "Notification" / milestone M5b.

## Context

A Claude session keeps running after the phone detaches (claude-ws.md). When it
then needs the user — a tool approval (auto-allow off), an `AskUserQuestion`, or
simply a finished turn — nobody finds out until they reopen the app. Worse,
before this ADR a detached `AskUserQuestion` was **skipped** (resolved with no
answers), so the model carried on without the input it asked for.

The operator wants the Messages-style experience: a banner with **Allow / Deny**
or the question's options, answerable from the notification shade.

## Decision

1. **FCM, content-free.** The daemon (`push.ts`, `firebase-admin`) sends a
   **data-only** message `{type: "permission"|"question"|"done", sessionId}` to
   every paired device with a registered token. Nothing else — no command text,
   paths or prompts transit Google. Sent only when **no client is attached**
   (an attached phone already has the WS frame). Android priority high; TTL
   120 s for `permission` (it's denied after that), 1 h otherwise.
2. **The phone fetches the details itself** over Tailscale:
   `GET /sessions/:id/pending` returns the waiting `permission_request` /
   `user_dialog` frames — exactly what the WS would have sent — and the app
   renders a local notification from them.
3. **Answer over REST.** `POST /sessions/:id/permission` `{toolUseID, allow}` and
   `POST /sessions/:id/dialog` `{dialogId, completed, result}` resolve through
   the **same** `PermissionGate.onPermission` / `onDialogResponse` as the WS
   frames, attributed to the calling device in the audit log. `410` when the
   request already resolved (answered elsewhere, timed out).
4. **The permission gate is unchanged.** 120 s → deny still holds. A push just
   gives the user a chance to answer inside that window; a late tap gets
   "Expired". A longer hold is a separate ADR (it widens the window a privileged
   command waits unattended).
5. **Detached `AskUserQuestion` now waits** (and pushes) instead of being
   skipped. It already had no timeout when attached; a question is not a
   privileged action, so waiting weakens nothing. A session nobody returns to is
   still bounded by the idle reaper, whose `stop()` cancels the question.
6. **Unlock to approve.** Prompt notifications are `VISIBILITY_SECRET` — never
   drawn on a secure lock screen — so Allow/Deny needs an unlocked phone
   (`flutter_local_notifications` has no per-action `setAuthenticationRequired`).
7. **Token registration:** `POST /devices/fcm {token}` writes the caller's own
   `devices.fcm_token`, clearing that token from any other row. Revoking a
   device deletes its row, so it stops receiving pushes. Tokens FCM reports as
   dead are nulled.
8. **Disabled by default:** no service-account key at
   `$VIBE_FCM_CREDENTIALS` (default `~/.config/vibe-daemon/firebase-sa.json`,
   `chmod 600`) ⇒ `push.ts` is a no-op.
9. **"Attached" must mean "looking at it".** Rule 1 keys on an attached client,
   so the app keeps attachment honest:
   - **Backgrounded ⇒ detached.** `ChatSessionController` closes its socket on
     `hidden`/`paused` (not `inactive` — shade/app-switcher peek) and reconnects
     on `resumed`, so the daemon sees no client and pushes.
   - **Attached but off screen ⇒ local notification.** A chat under another
     route, or a multi-chat tile while the grid isn't the top route, stays
     attached, so the daemon won't push. The controller raises the prompt
     locally (`PushService.notifyPrompt`), same builder + stable id as the push
     path so the two replace rather than duplicate.
   - **Visible ⇒ no notification.** ChatScreen and the grid register a
     per-session "on screen?" check (`PushService.registerVisible`); a session is
     visible when a check passes and the app is `resumed`. Foreground FCM
     messages and local prompts for a visible session are dropped — the card is
     already there.

## Consequences

- New outbound dependency on Google FCM, carrying only session ids + event type.
- The service-account key can send pushes to our app; it lives outside the repo,
  mode 600. `google-services.json` (client config) is gitignored.
- CLI sessions running outside the daemon (ADR 0012) push via a Claude Code
  `Notification` hook — see [ADR 0014](0014-cli-session-push-hook.md).
- The notification only reaches the phone while Tailscale is up on it (the
  detail fetch and answer go to the daemon over the tailnet).
