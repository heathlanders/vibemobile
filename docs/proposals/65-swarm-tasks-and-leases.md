# 65 — Swarm tasks + file leases (S1 + S2)

**Status:** building 2026-10-18 · steps S1 + S2 of proposal [64](64-swarm-and-prior-art-survey.md) · builds on [28](28-worktree-per-session.md) (worktrees), [30](30-session-peer-tools.md) (peer tools), notes (`notes.ts`)

## Problem

Several sessions can work on one project in separate worktrees, but they have no shared list
of work and no way to keep out of each other's files. You split the work by hand, and
overlapping edits only show up as conflicts at merge time.

## Design

### Tasks (S1)

- **Table** `tasks` in `SCHEMA` (db.ts), shaped like `notes`:
  - columns `id`, `project_id` (FK cascade), `title`, `body` (goal + acceptance criteria, Markdown),
    `scope` (JSON array of repo-relative paths), `deps` (JSON array of task ids), `state`,
    `session_id` (nullable), `created_at`, `updated_at`; index on `project_id`;
  - add `tasks` to the project-delete guard in `scanner.ts`, next to notes.
- **States:** `ready → running → review → done`, and back to `ready` from `running` or `review`
  (unclaim or reject). There is no separate `claimed` state: a claim *is* `running`.
- **Scope** is a list of repo-relative path prefixes (a file or a directory), not globs.
  - Two scopes overlap when one entry equals the other or is a directory prefix of it, compared
    on path segments: `src/a` covers `src/a/b.ts` but not `src/ab.ts`.
  - Paths are normalised: no `..`, no leading `/`, no `.git`. Limits: max 50 entries of 512 chars each.
  - An empty scope means "touches nothing exclusive". That's allowed, and the task gets no lease.
- **REST** (bearer-gated, same shape as notes):
  - `GET/POST /projects/:id/tasks`; `PUT/DELETE /tasks/:id`. PUT edits title, body, scope and deps
    only while the task is `ready`; it can also set `state` (any → `ready`, `review` → `done`).
  - `POST /tasks/:id/dispatch`:
    - The task must be `ready`, its deps must all be `done`, and no `running`/`review` task in the
      project may have an overlapping scope. Otherwise `409` with the blocker's id and title.
    - It creates a **worktree** Claude session (worktree is always on for tasks, per proposal 64)
      with `initialPrompt` built from the task (title, body, scope, "call `complete_task` when done").
    - It sets `state=running` and `session_id`, and **starts the first turn server-side**, so no
      client needs to attach. Today `initialPrompt` only fires in `getOrStart` on attach; dispatch
      calls the same start path itself.
    - Cap: at most `VIBE_SWARM_MAX` (default 3) tasks `running` per project, otherwise `409`.
      The live-session and worktree caps still apply.
  - Audit kinds `task.create`, `task.update`, `task.delete`, `task.dispatch`, `task.claim`, `task.complete`.
- **Peer tools** (Claude engine only, as with peer tools today):
  - `list_tasks`: the project's tasks with state, scope and deps, plus a `ready` flag meaning deps
    are done and nothing overlapping is held.
  - `claim_task {id}`: the same checks as dispatch, done in one transaction (`UPDATE … WHERE
    state='ready'`), binding the task to *this* session. Refused in plan mode and for sessions
    without a worktree.
  - `complete_task {id, summary}`: only the owning session can call it. The task moves to `review`
    and the summary is appended to the body under `## Result`. The phone gets a push (`task_review`).
- **Client** `app/lib/features/tasks/` (data/domain/presentation, copying `features/notes`):
  - a Tasks icon on the project screen opens a panel (sheet on mobile, dialog on desktop);
  - the panel shows a list grouped by state, a create/edit form (title, body, scope with one path
    per line, deps picker), and per-task actions: Dispatch, Open session, Mark done, Back to ready, Delete;
  - Refresh on open and pull-to-refresh. There are no live WS events in v1.

### Leases (S2)

- **A lease is not a separate record.** The active leases are the scopes of tasks in `running` or
  `review`, held by that task's `session_id`. The lock lifts by itself when the task reaches `done`
  or goes back to `ready`.
  - Keeping the lease through `review` stops new work on files that are about to merge.
  - The lease follows the task, not the process: if a session is idle-reaped, its claim survives.
    From the phone, Back to ready releases it.
- **Enforcement** in `ClaudeSession`'s `canUseTool` (claude.ts), before `gate.request`:
  - It covers the write tools `Write`, `Edit`, `MultiEdit` (`file_path`) and `NotebookEdit`
    (`notebook_path`).
  - The tool path is made relative to the session's checkout root (its worktree or the project
    path). Paths outside the checkout aren't leased and go through the normal file-scope check.
  - If another session's active lease covers the path: **deny**, with a message the model can act
    on: `"<path> is leased by task '<title>' (session <id>). Pick other files, or ask that session
    with send_message."` Audit `lease.deny`.
  - This applies to every Claude session in the project, task-bound or not, including normal chats
    in the main checkout. The holder's own session is never blocked.
- **Not a security boundary.** Leases are advisory coordination: Bash writes and the native engine
  aren't checked. Documented in `docs/security.md` as such.

## Verify

- Daemon tests:
  - task CRUD and validation (scope normalisation, `..`/`.git` refused, limits);
  - dispatch refusals (deps, overlap, cap, not ready);
  - `claim_task` atomicity: two claims race and exactly one wins;
  - `complete_task` by a non-owner is refused;
  - the lease deny path in `canUseTool`, plus allow for the holder and allow after `done`;
  - segment-wise overlap (`src/a` vs `src/ab.ts`);
  - dispatch starts the first turn with no client attached.
- `npm test` all green; `flutter analyze` clean; client widget/unit tests in the existing style.
- On a real box: dispatch 2 tasks with disjoint scopes; both run in their own worktrees. A third
  session editing a leased file gets the deny message and stops.

## Known limits / not done

- No merge back to main: that's S3 / [ADR 0032](../decisions/0032-swarm-merge-queue.md). In v1 a
  `review` task is merged by hand, then marked done.
- No change broadcast (S4), no planner (S5), no live board events (S6).
- Exclusive leases only. No shared leases, and no TTL (the claim lifts by task state).
