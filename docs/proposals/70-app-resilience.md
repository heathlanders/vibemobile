# 70 — App resilience: no lost messages, no surprise re-pair

**Status:** accepted 2026-11-19 · from the 2026-11-19 project review · client only

## Problem

The app loses user input and can drop its pairing on a transient error. Findings read in code on
2026-11-19 (v1.0.40). Paths are under `app/lib/`.

| # | Finding | Where |
|---|---------|-------|
| C1 | A message sent while the socket is down is lost: `sendUser` adds the bubble and calls `_socket?.sendUser` (no-op when null); `_send` has already cleared the input and attachments; the next `history` frame erases the bubble. | `features/chat/presentation/chat_session_controller.dart:462-472`, `:244`; `chat_screen.dart:875-883` |
| C2 | `looksLikeAuthError` is a substring match for "401"/"403" on the exception text. A match clears the token. A port number or id in the text can match. (trigger not reproduced) | `core/reconnect.dart:35-38`; `chat_session_controller.dart:232`; `chat_screen.dart:869-873`; `features/terminal/presentation/terminal_screen.dart:54` |
| C3 | `dioFor` sets no timeouts and builds a new `Dio` at each of ~68 call sites. Tailscale down = endless skeleton. | `core/providers.dart:19-25` |
| C4 | The close X in chat and terminal deletes the server session with no confirmation. | `chat_screen.dart:1215`, `:992-1003`; `terminal_screen.dart:62` |
| C5 | No draft persistence: composer text lives only in the widget controller. | `chat_screen.dart:141` |
| C6 | No way to type a newline on a phone: `TextInputAction.send` with `maxLines: 5`. | `chat_screen.dart:2194-2198` |
| C7 | Every stream delta calls `notifyListeners`; the whole body rebuilds and re-runs `groupToolRuns` + `galleryFromMessages` over all messages. | `chat_session_controller.dart:417`; `chat_screen.dart:1218-1257` |
| C8 | (inferred) Minimizing the desktop window pauses every chat socket (`hidden` lifecycle), and desktop has no push, so prompts go unseen. | `chat_session_controller.dart:168`; `features/notifications/data/push_service.dart:104-112` |
| C9 | One bad frame throws inside `applyFrame` (unchecked `as` casts). | `chat_session_controller.dart:351`, `:443` |
| C10 | Raw exceptions shown to the user (`Text('$e')`); reconnect banner has no "retry now". | `main.dart:192`; `features/sessions/presentation/project_sessions_screen.dart:138-173`; `chat_screen.dart:2258-2284` |
| C11 | Tool output cut at 2,000 chars with no way to see the rest. | `chat_screen.dart:1556` |

## Proposal

One PR per step, test first.

1. **C1.** When not live, put the turn (text + attachments) on the existing `_queued` list, show
   the bubble as "queued", flush on reconnect after `history`. Never clear the composer unless the
   controller accepted the turn.
2. **C2.** Decide auth failure from structured data only: the WS close code (4401/1008) or an HTTP
   status from an authenticated REST probe (`GET /devices` → 401). Never from `toString()`.
3. **C3.** One shared `Dio` per credentials (Riverpod provider) with connect 10 s / receive 30 s
   (longer for upload/download calls). Replace call sites mechanically.
4. **C4.** Confirm dialog on close for a session with history; or split into "Leave" (pop) and
   "End session" in the overflow menu. Pick one in the PR, keep it the same in chat and terminal.
5. **C5 + C6.** Save the draft per session id (debounced, `SharedPreferences`), restore on open,
   clear on accepted send. Phone: `TextInputAction.newline` and send by button only (desktop keeps
   Enter-to-send).
6. **C9.** Wrap `applyFrame` so a malformed frame is logged and skipped.
7. **C7.** Memoize `groupToolRuns`/`galleryFromMessages` on message count + last id; throttle delta
   notifications to ~30 Hz. Measure before/after with the DevTools frame chart on a long reply.
8. **C8.** Repro on Windows first. If confirmed, pause sockets on `hidden` only on mobile.
9. **C10 + C11.** Map errors to short messages with a Retry action; "Retry now" on the reconnect
   banner; "Show full output" on truncated tool results.

## Wire / schema impact

None. C2 relies on the 4401 close code from proposal 68 step 1 when that lands; the REST probe
works without it.

## Acceptance

- Widget/controller test: send while disconnected → bubble stays, turn is delivered after reconnect.
- Test: an error whose text contains "4013" or ":8403" does not clear the token; a 401 probe does.
- Test: REST call against a black-hole host fails within the timeout and shows the error state.
- Test: draft survives disposing and re-creating the chat screen.
- `cd app && flutter analyze && flutter test` green.
- On-device: airplane-mode send on the phone; long streaming reply stays smooth.

## What shipped

(fill in per step)
