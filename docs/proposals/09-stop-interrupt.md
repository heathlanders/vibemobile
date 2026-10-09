# Proposal 09 — Stop / interrupt

## Why
No way to cancel mid-stream. A long or wrong reply runs to completion; the only
escape is closing the session. Common, expected control.

## Sketch
Add a stop button (replaces send while streaming). Client sends an `interrupt`
frame; daemon aborts the in-flight SDK turn (AbortController on the query) and
emits a `result` with an interrupted subtype. Input queue stays intact for the
next turn.

## Impact
- **Wire:** add client→server `interrupt` frame
  ([claude-ws.md](../protocols/claude-ws.md)); `result.subtype` gains an
  interrupted value.
- **Schema:** none (audit to `events` as `turn.interrupted`).
- **Server:** wire an AbortController into the Agent SDK turn; cancel on
  `interrupt`. **Daemon-side**, not WS-close (must not detach the session).
- **Client:** send/stop toggle in `_Composer`.

## Open
- Partial assistant text already streamed: keep it (finalize as-is) vs discard.
  Default: keep what arrived.
