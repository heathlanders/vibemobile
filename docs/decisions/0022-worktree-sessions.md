# ADR 0022 — Worktree-per-session (isolated copy)

**Status:** Accepted (2026-10-07) — built (daemon + app). Implements proposal 28.

## Context

Several Claude sessions can run on one project (cap `VIBE_MAX_CLAUDE`). They all
edit the same checkout, so parallel sessions collide and an Auto-mode session can
trample uncommitted work. Mainstream harnesses solve this with one git worktree
per agent.

## Decision

`POST /sessions {kind:"claude", worktree:true}` creates a git worktree for the
session and runs the SDK with that directory as `cwd`.

- **Location:** inside the project, `<project>/.vibe-worktrees/<sessionId>`,
  branch `vibe/<first 8 of sessionId>`, from current `HEAD`, no carry-over of
  uncommitted changes. `sessionId` is server-minted, never client text.
- **Created with plain git**, not the SDK `WorktreeCreate` hook, via `gitRun`
  (ADR 0024 hardening: hooks off, fixed argv, scrubbed env):
  `git worktree add --no-track -b <branch> -- <path> HEAD`.
- **Preconditions:** project is a non-bare git repo with a born `HEAD`; else `400`.
  Claude engine only (native sessions have no write tools).
- **Persisted** on the session row: `worktree_path`, `worktree_branch`, `base_ref`.
  Every place that derives a session's cwd uses `worktree_path ?? project.path`.
- **Scope:** Auto-mode file scope for a worktree session is
  `[worktree_path, ~/.claude]` only — not the parent checkout or sibling projects —
  so an isolated agent cannot silently edit the main tree.
- **Cleanup:** `DELETE /sessions/:id` removes the worktree only if it is clean and
  has no commits beyond `base_ref` (no `--force`). Otherwise it is **kept** and the
  response says so (`{kept:true, path, branch}`); the user decides.
- **Hygiene:** scanner and tree listing skip `.vibe-worktrees`; the directory is
  added to the repo's `.git/info/exclude`. A worktree missing on disk marks the
  session stale — never a silent fallback to the main tree.
- **Audit:** `session.worktree.create|remove|kept` (device id, branch, path).

## Consequences

- First daemon git *write*; it is fixed-argv, server-named, no remote involved.
- The parent repo's `.git` is shared: a worktree agent with Bash can still touch the
  main repo's refs. Isolation is of the working tree, not a sandbox (same residual
  as ADR 0024).
- SDK transcripts are keyed by cwd, so resume must run from the worktree cwd
  (verified in the M8 spike).
- Keeping non-empty worktrees means disk can grow; surfaced in the session list,
  capped by a worktree count.
