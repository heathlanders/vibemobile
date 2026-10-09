# 42 — Branch a conversation ("branch from here")

**Status:** implemented (daemon + app + tests 2026-10-07; on-device check pending)

Take a conversation in a different direction without losing the original: copy it up to a
chosen user message into a new chat. Evidence: [M14 spike](../spikes/M14-spike-fork.md).

- **REST** ([session-rest.md](../protocols/session-rest.md#branch-a-conversation)):
  `POST /sessions/:id/fork {messageId, at?}` → `201` with the new session (`status:"stale"`,
  resumable; attaching it makes it live and enforces the live-session cap) and `copied` (history
  rows). `at:"after"` (default) keeps the chosen turn and its reply; `at:"before"` keeps only what
  precedes it, for rewriting that message.
- **Daemon** (`fork.ts`): `planFork` (pure) maps our rows to a cut in the SDK transcript using the
  stored `sdk_uuid`s; `forkSession` makes the transcript; our rows are copied with fresh ids and
  NULL `sdk_uuid`; the new row inherits project, model, mode and effort. Refused: unknown session /
  message (`404`), no SDK conversation yet, a turn running, an unmappable later message (`409`),
  bad body, worktree or native-engine sessions (`400`), project outside the allowed roots (`403`).
  SDK failures are generic `500`s that create nothing. Audited `session.fork`, 10/min.
- **App:** "Branch from here…" on a user message (long-press / right-click, next to Rewind) →
  `BranchSheet` (keep it, or branch before it) → opens the new chat **on top of** the original.
  Branching *before* a message puts its text in the new chat's composer (`initialDraft`); in a
  desktop workspace tab it goes to the clipboard instead.
- **Not carried over:** file checkpoints (rewind) — the fork starts with no undo history; the
  session's tags and title (the title becomes `↳ <title>`).

Out of scope: forking a worktree session (would need its own worktree), merging branches back,
a tree view of branches.

Tests: `vibe-daemon/src/fork.test.ts`, `app/test/fork_test.dart`.
