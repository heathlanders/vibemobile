# 32 — Turn status line ("Running Bash… 47s")

Status: **building**. Code and tests landed 2026-10-06. The check against a real
Agent SDK session on a device is still pending. No new security surface: a
read-only frame on the existing WS.

## Problem

While a prompt runs, the chat gives no steady sign of life. Nothing shows between
send and the first token, during thinking, or during a long tool run, so you can't
tell a working turn from a stalled one.

`busy` was also client-only, which broke it across reconnects:
- If the app was backgrounded through a turn's `result`, `busy` stayed true for good (stuck Stop button).
- A cold attach to a running turn showed `busy=false`.

## What shipped

**Wire.** A server → client frame, `{t:'status', running, phase?, tool?, elapsedMs?, idleMs?}`. It is documented in [claude-ws.md](../protocols/claude-ws.md).
- `phase` is one of `thinking`, `writing`, `tool` (+ tool name) or `waiting` (an approval/question card is open).
- Durations are relative, so there is no clock skew.
- When it's sent:
  - after `history` on every attach (this fixes the reconnect bugs)
  - on turn start
  - on phase change (never per delta)
  - every 5 s while running
  - once with `running:false` after `result`

**Daemon.** `turn-status.ts` `TurnStatus`, shared by both engines:
- `ClaudeSession`:
  - **turn start:** `pushUser`, or SDK `message_start` for a queued turn
  - **phase:** from `content_block_start` (thinking / text → writing / tool_use → tool name); a tool_result → thinking
  - **waiting:** while a `permission_request` / `user_dialog` is out; restored on answer
  - **end:** on `result`, a dead loop, or `stop()`
- `NativeSession`: the same, from `text-delta` / `tool-call` / `tool-result` parts. A turn spans the whole `drain()`, so queued messages stay "running".
- The heartbeat timer exists only while a turn runs (`unref`'d).

**App.**
- `chat/domain/turn_status.dart` turns a frame into state anchored to local receipt time, and holds `label()` and `stalledFor()`.
- `ChatSessionController.turn`: set from `status` frames, which also set `busy`. `sendUser` makes an optimistic local turn until the first frame arrives.
- `_TurnStatusLine` sits above the composer:
  - a spinner + `Thinking… 12s` / `Writing…` / `Running Bash… 1m 03s` / `Waiting for approval…`
  - ticks locally every second
  - hidden for mirrored CLI sessions, which have `_ExternalBanner`

**Stall hint.** The line turns amber with `· no activity 1m 10s` when either:
- no status frame has arrived for more than 15 s (the heartbeat is 5 s, so the link or daemon is gone), or
- the model has been quiet for more than 60 s while thinking or writing.

Tool runs and approval waits are exempt from the 60 s rule, because a long build is legitimately quiet.

## Known limits

- An app built against an old daemon (no `status` frames) shows the optimistic line, and after 15 s it shows "no activity". Ship the daemon first.
- A message sent mid-turn folds into the running turn's clock (the elapsed time doesn't reset).
