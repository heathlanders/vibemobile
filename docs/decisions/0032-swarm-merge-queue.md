# ADR 0032 — Swarm merge queue: rebase, test, fast-forward (phone-approved)

**Status:** Proposed (2026-10-18). Extends [ADR 0024](0024-git-write-surface.md)
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

1. **Queue.** A SQLite `merge_queue` table (task, session, branch, target, state, attempt,
   result). One worker per project, under the existing per-project mutex. FIFO. States:
   `queued → rebasing → testing → awaiting_approval → merged | bounced`.
2. **Target.** The branch checked out in the project's main checkout when the task was
   created. That target is recorded and not supplied by the client. The fast-forward
   needs the main checkout to be clean (tracked files) and on that target branch;
   otherwise the item waits and the phone is told why.
3. **Rebase** runs in the task's worktree: `git rebase <target>` via `gitRun`, with a
   longer timeout. If Mergiraf is installed, the daemon registers it only through `-c`
   (`merge.mergiraf.driver=…`) and a **daemon-owned** attributes file
   (`-c core.attributesFile=<daemon dir>/mergiraf.attributes`). If a conflict
   remains, the daemon runs `rebase --abort`, marks the item `bounced`, and sends the
   author session the conflict summary.
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
5. **Test command.** It is stored in daemon project settings (SQLite) and set only from
   a paired device. **It is never read from the repo.** It is an argv array (no shell)
   that must pass the exec allowlist. It runs in the worktree with a scrubbed env (no
   daemon secrets, no `VIBE_*`), a timeout (default 10 min), and an output cap. It is
   audited as `merge.test`. With no test command set, the item goes straight to approval,
   marked "untested".
6. **Approval.** A green item becomes `awaiting_approval`. The phone gets a push and
   shows the branch, target, commit range, diffstat and test result. On approve, the
   daemon runs `git merge --ff-only vibe/<sessionId>` in the main checkout, audited as
   `merge.ff`. A per-project `auto_merge` flag (default off) skips the approval step.
   **No push to a remote**: ADR 0024's rule stands.
7. **Bounce.** If the conflict, test failure or approval rejection returns to the author
   and the session is live, it gets a peer message (system sender, outside the
   per-sender rate limit) with the failure output, capped at 8000 chars. If the session
   isn't live, the task goes back to `ready` and the phone gets a push. Re-queueing
   increments `attempt`, capped at 3 before a human has to step in.
8. **Broadcast (S4).** After `merge.ff`, every other live session in the project gets
   a peer message listing the changed files and "rebase before continuing".

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
  checkout, and auto-merge off by default.
- Needs a `reviewer` pass before building (command execution plus repo writes).
