# 40 — Context meter and manual compaction

**Status:** implemented (daemon + app + tests 2026-10-07; on-device check pending)

Shows how full the model's context window is and lets you compact the conversation from the
phone. Evidence: [M12 spike](../spikes/M12-spike-context-compact.md).

- **Wire** ([claude-ws.md](../protocols/claude-ws.md)): server → `context`
  `{tokens, max, percent, autoCompactAt, categories[{name,tokens}], model}` after every turn,
  and on attach (the cached reading at once, a fresh one when idle); server → `compacted`
  `{text, trigger, preTokens, postTokens}` when the SDK compacts, manually or automatically;
  client → `compact`. Native engine: none of these.
- **Daemon:** `context.ts` (`summarizeContext` — defensive, only `kind:'used'` categories;
  `compactNotice`), `ClaudeSession.emitContext` (summary detail, ~20 ms, best-effort — a failed
  read never breaks a turn), `ClaudeSession.compact` (streams `/compact`, refused mid-turn / when
  stopped / before start, audited `session.compact`, not stored as a user message), and
  `compact_boundary` → a persisted `notice` row + the `compacted` frame.
- **App:** `ContextStrip` above the composer ("Context 26k / 1M · 3%", bar measured against the
  auto-compaction point, amber past 80%); tap → `ContextSheet` (usage, where auto-compaction
  happens, the biggest categories, **Compact now**, disabled with a reason while a reply runs).
  `ChatRole.notice` renders as a centred, muted line and is left out of copied transcripts.
- **Instructions in force.** The same response lists the instruction files the session loaded
  (`memoryFiles`: `CLAUDE.md` Project 1,489 tokens, auto-memory 344 …). The frame carries them
  (≤ 20, defensively parsed) plus `rules` — whether the daemon's session rules
  ([ADR 0026](../decisions/0026-session-rules-and-settings.md)) were appended when *this* session
  started — and the sheet shows both under **Instructions in force**, so "does this chat follow my
  rules?" is something you can see rather than assume. A chat started before the rules were enabled
  says "not applied".
- Frame parsing in the app is type-checked: a malformed `context` frame degrades to zeros
  instead of throwing out of the frame handler.

Out of scope: choosing what to keep when compacting (the SDK decides), per-project auto-compact
windows, a "context is nearly full" push notification.

Tests: `vibe-daemon/src/context.test.ts`, `app/test/context_test.dart`.
