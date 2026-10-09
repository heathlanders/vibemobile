# 37 — Switch model mid-session

**Status:** implemented (daemon + app + tests 2026-10-07; on-device check pending)

Change a Claude session's model without starting a new one — same conversation,
new model from the next turn. Until now the model was fixed at create and the only
route was "Hand off" (new session + a summary prompt).

- **Wire** ([claude-ws.md](../protocols/claude-ws.md)): client → `{t:"set_model", model}`;
  server → `{t:"model", model, canSwitch:true}` on attach and after every successful
  switch. The native engine never sends `model`, so the app hides the action there.
- **Daemon** (`claude.ts` `setModel`): `Query.setModel(id)`, then `sessions.model` is
  updated and audited (`session.model`). Refused (no change, no frame) for: native-provider
  ids (`openai:…`, `google:…`, `ollama:…` — a different engine, use Hand off), empty/overlong/
  whitespace ids, the current model, a stopped session, or a model the SDK rejects.
  Checked against the real SDK: after `setModel('haiku')` the next turn is answered by
  `claude-haiku-4-5` (the SDK re-emits `init` with the new model).
- **App:** "Switch model…" in the chat menu (only when the daemon sent `canSwitch`), using
  the existing model picker; a `provider:model` pick is refused locally with a pointer to
  Hand off.
- **Bug found on the way (fixed):** `setModel` makes the CLI emit a synthetic `user`
  message whose `content` is a **string**. `ClaudeSession.handle` called `.filter` on it,
  threw out of the consume loop and ended the session ("Query closed before response
  received"). Any non-array content now means "no blocks" (`contentBlocks`), with a
  regression test (`model-switch.test.ts`).

Out of scope: switching to a native-provider model, per-turn model, effort/thinking-budget
control.

Tests: `vibe-daemon/src/model-switch.test.ts`, `app/test/thinking_test.dart` (model frame).
