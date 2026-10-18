# ADR 0032 — Swarm merge queue: rebase, test, fast-forward (phone-approved)

**Status:** Accepted (2026-10-18; proposed the same day). Extends [ADR 0024](0024-git-write-surface.md)
(local git writes, no rebase/merge) and [ADR 0022](0022-worktree-sessions.md)
(worktree per session). Implements S3 of [proposal 64](../proposals/64-swarm-and-prior-art-survey.md).

## Context

Proposal 64 lets several worktree sessions work on one project's tasks at once. Each one
ends with commits on `vibe/<sessionId>`. Nothing brings that work back: ADR 0024 stops
at stage/commit/branch, and rebase and merge return 404. Merging by hand from the phone
doesn't scale to N sessions, and merges that are clean as text can still break the
build. Prior art (GitHub merge queue, the Gas Town "Refinery", Graphite) agrees on one
pattern: merge one change at a time, rebase it first, run the tests, then fast-forward.

There are two security facts, and the second one is new:

1. The merge queue runs the project's test command, which executes code the agent wrote
   (test files, `package.json` scripts). The command line is fixed by the daemon, but
   **what it runs is not**.
2. **`GIT_HARDEN_ARGS` (`git-run.ts`) doesn't neutralise filter, merge or textconv
   drivers.** The agent can write `.git/config` (`filter.<x>.clean/smudge/process`,
   `merge.<x>.driver`, `diff.<x>.textconv`) and `.gitattributes` / `.git/info/attributes`
   to point paths at them. Git then runs those commands during checkout, rebase,
   merge, `add` and some `diff`/`status` calls. Rebase and merge depend on this
   machinery, so `-c` overrides can't cover every driver name. **This already affects
   the existing `stage` route (`git add` runs clean filters).** That isn't new risk
   from this ADR, but this ADR must not widen it.

## Decision

v1 is cut down after a pre-build `reviewer` pass (2026-10-18): no Mergiraf, no `auto_merge`,
no automatic requeue. Git on the box is 2.34, so nothing here needs `git replay`,
`merge-tree --write-tree` or `rebase.updateRefs`.

1. **Queue.** A SQLite `merge_queue` table (task, session, target branch, `target_sha`,
   `tested_sha`, state, attempt, result). Only the phone enqueues, and only a task in
   `review`. One worker per project, under a **new** lock module `project-lock.ts` keyed by
   the realpath of the project. `git-write.ts` and `project-files.ts` switch to it, so a
   merge can't interleave with phone git writes or file saves. Items are FIFO. States:
   `queued → rebasing → testing → awaiting_approval → merged | bounced`.
2. **Target.** When the worktree is created, the daemon records the main checkout's
   `symbolic-ref --short HEAD` in a new `sessions.target_branch`. With a detached HEAD
   there is no target, and the session can't be queued. The client never supplies it.
   **Refs are always resolved fully qualified**, using
   `rev-parse --verify --end-of-options refs/heads/<name>`, and from then on only shas are
   used, so a tag named `main` or `vibe/<sid>` can't shadow the branch.
3. **Rebase** runs in a **daemon-owned detached worktree**, `$VIBE_MERGE_DIR/<itemId>` (set in the daemon env to a cache dir on the data disk; the queue refuses to run without it).
   It is created like `worktree.ts` creates worktrees (`--no-checkout`, then `reset --hard`
   from inside) and lives outside the project, so the author session can't race it or edit
   it.
   - The author's worktree must be clean (`status --porcelain` is empty); otherwise the
     item bounces with "commit first".
   - The rebase command is `rebase --no-gpg-sign --onto <targetSha> <mergeBase> <branchSha>`,
     with the daemon's own `user.name`/`user.email`.
   - **Before each call, the daemon verifies the git layout.** `rev-parse --git-common-dir`
     must canonicalise to the project's `.git`, `--absolute-git-dir` to its
     `worktrees/<name>`, and `--show-toplevel` to the cwd. A `core.worktree` or `core.bare`
     key fails the check.
   - On a conflict, the daemon runs `rebase --abort` and marks the item `bounced`. The
     abort also runs in a `finally` and on startup for any item left in `rebasing`.
     Startup requeues those items.
   - The scratch worktree is removed when the item finishes.
4. **Driver check (fixes fact 2 for every daemon git call; built 2026-10-18 ahead of
   the queue).** Before each call, `gitRun` reads `git config -z --list` **in the cwd the
   call runs in**; the list follows `include.path` and `includeIf`. It throws
   `UnsafeGitConfigError` (the routes return `409 repo_config_unsafe: <key>`) on any
   `filter.*.{clean,smudge,process}`, `merge.*.driver`, `diff.*.{textconv,command}` or
   `includeIf.onbranch:*` key. An onbranch include changes with the checked-out branch,
   so checking on one branch proves nothing about the next.
   - **No git-lfs exception:** git-lfs reads its own config, which can name commands to run.
   - **Worktrees** are created with `--no-checkout` and then populated by `reset --hard`
     run inside the worktree. This matters because `includeIf gitdir:` matches differently
     in a worktree than in the main checkout.
   - **Submodules** have their own config, which this check can't see, so daemon `status`
     calls pass `--ignore-submodules=all` and stage-all (`add -u`) is refused when the index
     has gitlinks.
   - Found in review: `git-run.test.ts` has control tests proving each plant fires without
     the fix. A per-project allowlist set from the phone is deferred until someone needs it.
   - **Added with the queue: signing and editors.** `gpg.program` runs during rebase,
     `merge` and `log`; the pre-build review reproduced this. `GIT_HARDEN_ARGS` gains
     `gpg.program`, `gpg.ssh.program` and `gpg.x509.program` set to `false`, plus
     `commit.gpgSign=false`, `merge.verifySignatures=false`, `log.showSignature=false`,
     `core.editor=false` and `sequence.editor=false`. `gitEnv` sets `GIT_EDITOR=false`.
     Control tests are added.
5. **Test command.** It is stored in a new per-project `project_settings` table, set only
   from a paired device (REST, audited), and **never read from the repo**. Proposal 60
   phase 2 isn't built, so **this ADR defines the exec allowlist**:
   - The command is an argv array with no shell.
   - `argv[0]` resolves to an absolute path **outside the repo**, from a fixed set of
     runners (`npm`, `pnpm`, `yarn`, `node`, `npx`, `dart`, `flutter`, `cargo`, `make`,
     `pytest`, `python3`, `go`). It is checked when set and again when run.
   - It runs in the scratch worktree with an **allowlisted env**: a fixed `PATH`, `HOME`,
     `LANG`, `TMPDIR`, the cache-path variables from the daemon env, and `CI=1`.
   - It runs under `systemd-run --user --scope` with `RuntimeMaxSec` (default 10 min) and
     `MemoryMax`, so grandchildren die with the cgroup. Without systemd, it runs in its own
     process group, which is killed after exit and on timeout.
   - Output keeps only the last 64 KB. The run is audited as `merge.test`.
   - With no test command set, the item goes to approval marked "untested".
6. **Approval.** When an item reaches `awaiting_approval`, the phone gets a push and shows
   the target, the `target_sha..tested_sha` commit range, the diffstat and the test result.
   - The approve request carries `{sha}`. The daemon refuses it unless `sha == tested_sha`
     and `refs/heads/<target>` is still at `target_sha`; if the target moved, the item is
     requeued.
   - The main checkout must be clean (tracked files) and on the target. A file the merge
     would **add** must not already exist on disk there; this stops an ignored `.env` from
     being overwritten. No path may be added under `.vibe-worktrees/`.
   - The daemon then runs `merge --ff-only --no-verify-signatures <tested_sha>` in the main
     checkout, audited as `merge.ff`.
   - The author's branch is moved to the merged sha with a compare-and-swap `update-ref`,
     and `sessions.base_ref` is set to it.
   - **No `auto_merge` in v1; that needs a later ADR.** **No push to a remote**: ADR 0024's
     rule stands.
7. **Bounce.** A conflict, test failure or rejection bounces the item.
   - If the author session is live, it gets a daemon turn labelled "not typed by the user"
     with the failure output as data, capped at 8000 chars.
   - If the session isn't live, the task goes back to `ready` and the phone gets a push.
   - Only the phone requeues. Each requeue increments `attempt`; after 3, the phone has to
     reset the task.
   - While an item is active, `DELETE /sessions/:id` and worktree removal for its session
     are refused.
8. **Broadcast (S4).** After `merge.ff`, the queue calls `broadcastTaskDone` with the
   range `<target_sha>..<tested_sha>`, so the list holds only this task's files.

## Consequences

- Parallel sessions get back to main without hand merges, one at a time and tested.
  Serial merging is slower than batching, which is acceptable at a 3–6 session scale.
  Batching and bisecting (as in the Refinery) can come later.
- **Residual risk, stated plainly:** the tests execute agent-written code with the
  daemon user's rights. That is the same as an agent running `npm test` through Bash in
  Auto mode, but it skips the per-tool permission prompt in Ask mode. The fixed argv
  stops the agent from *choosing* the command, not from changing what it runs. A real
  sandbox (container-use style) is out of scope and would need its own ADR.
- The driver check can break repos that legitimately use filters (LFS, git-crypt)
  until their keys are allowlisted. The 409 names the key.
- Main moves under live sessions. Broadcast plus rebase-before-continuing handles the
  common case; files leased by S2 don't overlap, so most rebases are clean.
- New surface to document: `merge_queue` routes and WS events in
  `docs/protocols/session-rest.md`, a new row in `docs/security.md`, and the new tests:
  conflict bounce, red-test bounce, unsafe-config 409, ff-only refusal on a dirty main
  checkout, sha-pin mismatch, tag shadowing, ignored-file overwrite refused, gpg control tests, and recovery after a restart mid-rebase.
- **What approval does not stop:** phone approval and phone-only settings stop a session
  in Ask mode and prompt injection through the Write tool. They do **not** stop an
  Auto-mode agent that has Bash. Such an agent runs as the daemon user, so it shares the
  refs, `.git/config` and the daemon DB, and it can move `main` itself. The same holds
  for test code, which can read `HOME`.
- The gap between the config check and the git call now spans a whole rebase, which the
  scratch worktree keeps short. It is not closed.
- The `reviewer` pass was done 2026-10-18 (findings H1–H4, M1–M6); the edits above apply it.
