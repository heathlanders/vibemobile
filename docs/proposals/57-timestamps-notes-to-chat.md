# 57 — Message timestamps; build open Notes in a chat

**Status:** building 2026-10-11; on-device check pending

Two items from the project's Notes. Client only.

- **Timestamps on chat messages.** Each user and assistant bubble has a small muted time under
  it: `14:03:22` today, `Oct 9 14:03:22` on another day, `Oct 9 2025 14:03:22` in another year.
  `ChatMessage.at` comes from the daemon's `ts` for rows replayed from history; a live row uses
  the time this client first saw it (replaced by the server time on the next history replay).
  Tool, thinking and notice rows show no time.
- **"Build in chat" in the Notes sheet.** Enabled while there are open notes. Pick a model, and a
  new chat opens in the project with the composer pre-filled: the open notes as a list, under the
  inbox workflow (capture each in the docs, build and test it, tick it off with `resolve_note`,
  proposal 56). Nothing is sent until the user sends it. Uses the existing session-create call
  and `ChatScreen.initialDraft`; no daemon change.
