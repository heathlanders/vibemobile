# Proposal 10 — Message search

## Why
Transcripts grow unbounded; no way to find a past message. Locating an earlier
command or answer means scrolling.

## Sketch
Per-session search over the `messages` table. REST `GET /sessions/:id/messages?q=`
returns matching rows (with ts for jump-to). Client search bar in the chat;
tapping a hit scrolls to it. Phase 1 = `LIKE`; FTS5 if it gets slow.

## Impact
- **Wire:** none (REST, not WS).
- **Schema:** none for `LIKE`; optional FTS5 virtual table later.
- **Server:** `GET /sessions/:id/messages?q=` ([session-rest.md](../protocols/session-rest.md)).
- **Client:** search field + result list + scroll-to-index in `ChatScreen`.

## Open
- Scope to one session vs cross-session (defer cross-session to dashboard).
- Search tool input/results too, or assistant/user text only.

## Status (2026-10-06)
Shipped, including jump-to. Tapping a hit closes search and scrolls to the
bubble, which gets a brief tint.
- **Matching:** `history` rows now carry `ts` onto `ChatMessage.ts`, so a hit
  matches its exact bubble even when the text repeats. Turns that arrived live
  (no ts until a reattach) fall back to the newest same-role row with identical
  text (`findHitIndex`, unit-tested).
- **Scrolling:** the list is lazy with variable row heights, so the chat jumps to
  a proportional offset until the row is built, then `Scrollable.ensureVisible`
  places it.
- A hit outside the loaded transcript shows a snackbar.
- Only user/assistant text is searchable (tool rows store no `content`).
