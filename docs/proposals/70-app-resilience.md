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

- **C1** (2026-11-19). `sendUser` on a controller that is not `live` (connecting, reconnecting,
  backgrounded) puts the turn (text + attachment ids) on `_queued` and shows the bubble as
  "Queued · sends when reconnected" (`ChatMessage.queued`, never cached). The queue flushes after
  the next `history` frame instead of on connect, because the replay cleared the bubbles (this
  also fixes `sendWhenLive` turns vanishing). `_pause` now leaves `live`, so a send while
  backgrounded queues instead of going to a closed socket. The composer clears as before:
  every non-empty send is now accepted. Test: `chat_offline_send_test.dart` against a real local
  WebSocket server that drops mid-session (old code: turn never delivered). Six older tests that
  drove `sendUser` on a bare controller now mark it `live` first. Not checked on a device yet
  (airplane-mode send).
- **C2** (2026-11-19). `looksLikeAuthError` (substring match on the exception text) is gone. After
  a failed WS upgrade both controllers call `tokenRejected` (`core/auth_probe.dart`): `GET /devices`
  with the same token, 10 s timeouts; only 401/403 re-pairs, anything else (including unreachable)
  retries. A socket that closes keeps using its close code (4401 → re-pair). Real trigger found:
  the exception text carries the URL, so a hex session id containing "401"/"403" re-paired on any
  failed upgrade. Test: `auth_probe_test.dart` against a real local server (session id
  `s_c4013a` + 500 → no re-pair, red on old code; 401 probe → re-pair).
- **C3** (2026-11-19). `dioFor` now returns one cached `Dio` per base URL + token (a re-pair gets
  a new one) with connect 10 s / receive 30 s. No Riverpod provider: caching inside `dioFor` gives
  the same sharing without touching the 68 call sites. Dio 5.9's `receiveTimeout` bounds the wait
  for response headers and the gaps between chunks, not the whole transfer, so uploads and downloads
  keep working on the default. Calls that can run longer (git stage/commit/branch, CI via `gh`,
  fork, rewind, session create with a worktree, session delete, prune, task dispatch, merge
  approve, project create) pass `slowCall()` (5 min). The list came from a `scoper` pass over
  the daemon routes. Improve keeps its own 90 s. Tests: `dio_for_test.dart` (shared instance +
  timeouts, red on old code; a black-hole TCP host fails with `receiveTimeout`). Not covered: a
  widget test that a screen shows its error state on timeout.
- **C4** (2026-11-19). Picked the confirm dialog (not a Leave/End split): the close X in chat and
  terminal asks "End session?" (`confirmEndSession` in `session_actions.dart`, shared). Cancel
  leaves it running; End deletes as before. Always asks, history or not, so the two screens stay
  the same. Test: `end_session_confirm_test.dart` (chat: Cancel → not closed, End → closed; red on
  old code). Terminal uses the same helper but has no widget test of its own.
- **C5 + C6** (2026-11-19). C5: `DraftStore` (SharedPreferences, `draft:<sessionId>`) saves the
  composer text 500 ms after typing stops and when the chat is left, with paste tokens expanded;
  restored on open unless there is an `initialDraft` or the user already typed; an accepted send
  empties the box, which removes the entry. Best-effort: a storage error means no draft. C6: the
  composer uses `TextInputAction.newline` on every platform, so a phone's Enter inserts a line
  and sending is the button; desktop keeps Enter-to-send via its key handler. Tests:
  `chat_draft_test.dart` (draft survives dispose + re-create, red on old code; an accepted send
  clears it; newline action). The newline test can't be red on the Linux test host (desktop was
  already newline there). Not checked on a phone yet.
- **C9** (2026-11-19). `applyFrame` wraps the reducer: a frame with a field of the wrong type is
  skipped with a debug log instead of throwing out of the socket listener. `ClaudeSocket.frames`
  drops payloads that aren't a JSON object instead of erroring the stream, which closed the session
  and reconnected. Tests: `chat_bad_frame_test.dart` (mistyped `assistant`/`history`/`tool_use`
  frames skipped, later frames apply; non-JSON and array frames on a real socket leave it live
  with no reconnect; both red on old code). A frame that throws halfway may leave that one
  frame's partial change in place.
- **C7** (2026-11-19). The controller coalesces `delta`/`thinking_delta` notifications to ~30 Hz
  (one 33 ms timer); every other frame notifies at once and bumps `revision`. The chat screen
  keeps `groupToolRuns` + `galleryFromMessages` (the latter regex-scans every finished reply)
  keyed on `(messages.length, revision)`, so a streaming bubble no longer re-derives the whole
  transcript. Measured with a throwaway widget probe (real `ChatScreen`, 2,000 messages, 300
  deltas, one 16 ms frame each, debug test runner, 3 runs each): **14.2 s → 8.8 s** (−38%).
  Not measured with the DevTools frame chart on a phone. Test: `chat_stream_throttle_test.dart`
  (300 deltas → ≤ 4 notifications, text complete; red on old code: 300). One older test now pumps
  50 ms for a delta to show.
- **C10 + C11** (2026-11-19). C10: `core/errors.dart` `friendlyError(e)`: timeouts → "didn't
  answer in time", unreachable / socket errors → "Can't reach the server. Check that Tailscale is
  connected.", a daemon `{error}` body → that text, other 5xx → "The server hit an error (N)",
  our API exceptions → their message, anything else → "Something went wrong". Replaces all 10 raw
  `Text('$e')` sites; the app root's error screen gains Retry (re-reads creds). The reconnect banner
  shows **Retry now** (`ChatSessionController.retryNow`, skips the backoff). C11: a tool result over
  2,000 chars shows **Show full output** (scrollable, selectable dialog). Tests:
  `friendly_error_test.dart`, `retryNow` in `chat_offline_send_test.dart` (reconnects in < 300 ms,
  below the 0.4 s minimum backoff), `tool_full_output_test.dart` (red on old code). Caveat: in the
  test harness a real tap on the button never reached it (the hit test landed on the list), so
  the test presses it directly; check by hand on a device that the button responds. The terminal's
  banner has no Retry now yet. Pairing errors still show raw text (separate screen).
