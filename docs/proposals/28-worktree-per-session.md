# 28 — Git worktree per Claude session

**Status:** built — [ADR 0022](../decisions/0022-worktree-sessions.md); daemon + app (on-device check pending)

## Problem

The multi-chat grid (proposal 19) runs up to 6 Claude sessions at once, but sessions
on the same project share one working tree: two sessions editing the same repo
clobber each other's files and branches, and `git status` becomes meaningless. The
workaround is one session per project, which defeats the grid.

## Decision (proposed)

An opt-in "Isolated copy" toggle at session creation (`POST /sessions
{worktree:true}`, claude only):

- Daemon creates `git worktree add <root>/.vibe-worktrees/<project>-<sessionId> -b
  vibe/<sessionId>` and uses that path as the session `cwd`; the row stores
  `worktree_path` + `worktree_branch`.
- The SDK also has a `worktree` option (`sdk.d.ts`: symlinks, sparse paths,
  `fresh`/`head` base) — evaluate whether to delegate to it vs. calling git
  ourselves. Prefer git directly: it keeps creation/cleanup auditable in our code
  and matches ADR 0011's argv-only style.
- Cleanup on `DELETE /sessions/:id`: if the worktree is clean, remove it and its
  branch; if dirty or the branch has commits, **keep it** and tell the phone
  where it is (never delete work).
- Client: toggle in the new-session sheet; a branch badge on the session; the
  changed-files viewer already works because it reads the session's own edit set.

## Security / risk

First git **write** (extends ADR 0011, which deliberately built none):

- Fixed argv via `execFile`, no client-supplied argument — branch/path derive from
  the server-minted session id only.
- Worktree path must resolve inside `projectRoots()` (`pathInRoots`), and the
  `.vibe-worktrees` directory must be excluded from the project scanner and
  `project-tree.ts` so worktrees don't show up as projects.
- No push, no remote operations, no `git add -A` (the exact risks ADR 0011 names).
- Audit `session.worktree.create/remove` with device id. Needs its own ADR + a
  `git.test.ts`-style test with real temp repos, plus a test that commit/push
  routes still 404.

## Open questions

- Disk/RAM: `node_modules` per worktree (the SDK option's symlink list helps).
- Merging back: out of scope — the branch is for the user to merge on the PC.
- Resume after worktree deletion by hand.

## Verification

Real temp-repo tests for create/cleanup/dirty-keep; two sessions on one project edit
the same file concurrently without interference; daemon restart → resume still uses
the worktree cwd.
