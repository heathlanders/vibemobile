# Proposal 15 — initialPrompt atomicity

## Why
The first user turn (e.g. a filled template, `ChatScreen.initialMessage`) is sent by
the client *after* the WS connects. That's a race: the connect/attach handshake and
the first turn are two steps, and a drop between them loses or reorders the opening
prompt. Also a dependency for proposal 04 (templates) and 12 (auto-title).

## Sketch
Carry the first turn with session creation: `POST /sessions { kind, initialPrompt }`.
The daemon queues it as the first `pushUser()` when the SDK starts on attach — one
atomic create-and-prime, no client-side post-connect send.

## Impact
- **Wire:** optional `initialPrompt` on `POST /sessions`
  ([session-rest.md](../protocols/session-rest.md)).
- **Schema:** transient (queued at SDK start) or stored on the `sessions` row.
- **Server:** seed the input queue before the first SDK iteration.
- **Client:** pass `initialMessage` to create instead of sending post-connect
  (chat_screen.dart:39).

## Open
- Store `initialPrompt` (for resume/replay) vs consume-once.
- Interaction with reattach — must not re-send on every attach.
