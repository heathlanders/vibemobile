# 27 — Checkpoint / rewind a turn's file edits

**Status:** built — [ADR 0023](../decisions/0023-checkpoint-rewind.md); daemon + app (on-device check pending)

## Problem

Auto-allow is the default, so Claude's edits land without a tap — and on a phone
you can't review a diff carefully. When a turn goes wrong the only recovery is
asking Claude to undo it (unreliable) or SSH + `git checkout` (git is read-only in
the app, ADR 0011). There is no "undo that turn".

## Decision (proposed)

Use the SDK's own file checkpointing rather than building git plumbing:

- Start queries with `enableFileCheckpointing: true` (`sdk.d.ts`); each user
  message becomes a restore point, identified by its message id.
- New REST `POST /sessions/:id/rewind {toMessageId, dryRun?}` →
  `Query.rewindFiles(userMessageId, {dryRun})`. `dryRun` returns what would change
  (files, insertions/deletions) so the phone shows a confirm sheet first.
- Client: "Rewind files to here" on a user bubble's long-press menu (next to
  retry/edit, proposal 11), with the dry-run summary in a confirm sheet.
- Conversation is **not** rewound — only files. (Rewinding the transcript is a
  fork, a separate feature; the SDK has `forkSession`.)

## Security / risk

This is a new **write** surface: it restores file contents on the server.

- The SDK restores only files it tracked as edited by this session's tools; the
  daemon takes no client path — only a message id belonging to this session
  (checked against `messages`).
- Re-check every returned path with `pathInRoots` (paths.ts) before reporting; refuse
  and audit if anything is outside the project roots.
- Audit `session.rewind` with device id and file count; rate-limit like other
  write routes. Needs a `security.md` row and an ADR before building.
- Edits made via Bash (`sed -i`, `rm`) are **not** tracked by SDK checkpointing —
  say so in the confirm sheet rather than imply a full undo.

## Open questions

- Checkpointing cost on big repos (it copies files before edit).
- Resumed sessions after a daemon restart: are checkpoints still valid?
- Interaction with the changed-files viewer (`file-edits.ts`): show rewound edits
  as reverted.

## Verification

Spike first (like M7): a session edits two files over two turns → dry-run → rewind
to turn 1 → files match, Bash-created files untouched. Then daemon tests with a fake
`rewindFiles`, then an on-device walkthrough.
