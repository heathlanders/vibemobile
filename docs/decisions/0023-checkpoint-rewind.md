# ADR 0023 — File checkpoint / rewind

**Status:** Accepted (2026-10-07) — built (daemon + app). Implements proposal 27.
Evidence: [M8 spike](../spikes/M8-spike-checkpoint-rewind.md).

## Context

When an agent edits the wrong files there is no undo from the phone. The SDK has
`enableFileCheckpointing` and `Query.rewindFiles(userMessageId, {dryRun})`.

## Decision

Enable file checkpointing on Claude-engine sessions and add
`POST /sessions/:id/rewind {messageId, dryRun?}`.

- **uuid plumbing:** the daemon mints a uuid per user message, sends it as
  `SDKUserMessage.uuid`, and stores it in `messages.sdk_uuid` (nothing echoes it).
- **Capability, not paths:** the client sends a daemon `messages.id` of a *user*
  message in that session. It never sends a path or raw uuid. Unknown/foreign id ⇒ `404`.
- **Semantics (spike):** `rewindFiles(u)` restores the state from *before* `u`'s
  edits — it undoes `u` and everything after. UI copy says exactly that.
- **Dry run first, always.** The route calls `dryRun`, then checks every
  `filesChanged` (absolute) with `canonical` + `pathInRoots` (`file-scope.ts`). Any
  path outside the session's roots ⇒ refuse the real call. Real runs return no file
  list, so the dry-run list is what is reported.
- **Not mid-turn:** `409` while a turn is in flight.
- **Wire:** server→client `{t:"rewound", messageId, filesChanged, ts}` so other
  attached clients refresh; `history` replay frames gain the message `id`, and a `user_ack {messageId}`
  frame gives a live-sent bubble its id (Flutter: FIFO onto the newest un-acked user bubble).
- **Audit:** `session.rewind` / `session.rewind.dry` (device id, message id, file count).
- **Claude engine only.** Native sessions have no checkpointing.

## Consequences

- **Bash edits are not tracked** (spike): the UI warns "edits made via Bash aren't
  undone".
- `skippedLinks` (symlinks etc. refused by the SDK) is surfaced.
- Checkpoints survive a fresh `resume` (spike). `forkSession` drops them (SDK doc),
  which matters for the later "branch from here" follow-up: rewind files first, then fork.
- Conversation rewind is out of scope here.
