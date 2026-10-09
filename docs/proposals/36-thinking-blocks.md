# 36 — Thinking blocks

**Status:** implemented (daemon + app + tests 2026-10-07; on-device visual check pending)

Show the model's summarized reasoning in the chat, collapsed. Evidence:
[M9 spike](../spikes/M9-spike-thinking.md).

- **Daemon** (`claude.ts`): `start()` passes `thinking:{type:'adaptive',display:'summarized'}`
  unless `VIBE_SHOW_THINKING=0|false|off|no`. `thinking_delta` stream events are
  forwarded as `{t:"thinking_delta", text}`; the final assistant `thinking` block is stored
  as a `messages` row with role `thinking` and sent as `{t:"thinking", text}` **before** the
  answer's `assistant` frame. Empty/omitted blocks produce nothing. Native-engine sessions
  are unaffected (no thinking).
- **History:** `history.messages[]` may contain `role:"thinking"` rows
  ([claude-ws.md](../protocols/claude-ws.md)).
- **App:** `ChatRole.thinking`; the controller builds one streaming row from the deltas and
  the final frame replaces it in place. `ThinkingTile` (`chat_screen.dart`): muted,
  collapsed by default, "Thinking…" while streaming then "Thought"; excluded from the copied
  transcript and from the multi-chat tile tail.
- **Cost / privacy:** summaries are billed model output like any other; they stay on the
  same authenticated channel as the rest of the transcript. No new endpoint.

Out of scope: an effort/thinking-budget control (next), thinking for mirrored CLI sessions
(`external.ts` / transcript import ignore thinking blocks), searching thinking text.

Tests: `vibe-daemon/src/thinking.test.ts` (fake SDK replaying the spike's shapes),
`app/test/thinking_test.dart`.
