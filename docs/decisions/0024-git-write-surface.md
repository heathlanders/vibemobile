# ADR 0024 — Git write surface: hardening, stage, commit, branch (no push)

**Status:** Accepted (2026-10-07) — built (daemon + app). Extends ADR 0011,
which specified writes but deferred them.

## Context

ADR 0011 made git read-only and listed prerequisites for writes. Worktree sessions
(ADR 0022) make committing the natural way to finish work. A security fact changes
the threat model: **the agent can write `.git/hooks/*` and `.git/config`** through
ordinary tools or Bash. Any daemon-run git command therefore executes whatever the
repo says — `core.fsmonitor`, `core.sshCommand`, `credential.helper`,
`diff.external`, hooks — with the daemon's rights. This already applies to today's
`git status`.

## Decision

1. **Harden every daemon git call (P1, includes existing `git status`).** One
   `gitRun(cwd, argv)` helper: `execFile` (no shell), fixed argv, timeout, output
   cap, with
   `-c core.hooksPath=/dev/null -c core.fsmonitor=false -c core.sshCommand=ssh
   -c credential.helper= -c diff.external=` and a scrubbed env
   (`GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 GIT_OPTIONAL_LOCKS=0`).
2. **New write routes** in `git-write.ts` (so `git.ts` stays read-only), both
   project-scoped and session-scoped (`/sessions/:id/git/...`, primary for worktrees):
   - `stage {paths?}` — relative paths, no leading `-`, `canonical`+`pathInRoots`,
     passed after `--`. Never `add -A`. Default = tracked changes in the session's
     edit set. Secret-file deny list (`.env*`, `*.pem`, `id_*`, `*.key`, `.git/**`)
     unless `allowSensitive`.
   - `commit {message}` — 1–500 chars, no NUL, leading `-` rejected, passed as the
     value of `-m`. Identity `user.name=<device name>`, `user.email=<device id>@vibe.local`.
     `--no-verify`, `commit.gpgsign=false`. Audit `git.commit` (message cut to 80).
   - `branch {name}` — `^[A-Za-z0-9][A-Za-z0-9._/-]{0,63}$` plus
     `git check-ref-format --branch`. Create-and-switch only; no delete, no force;
     refuse a switch when tracked files have uncommitted changes (untracked files don't block).
3. **Per-project mutex** and per-device rate limit on all write routes.
4. **No push in this ADR.** The commit/stage routes exist; `push` still returns
   `404`. A later ADR must cover: opt-in `VIBE_GIT_PUSH=1`, server-chosen remote
   (never client-supplied), TOFU-pinned remote URL, scheme allowlist, confirm
   sheet showing remote/branch/sha, no force.

## Consequences

- Commit is a local-only effect, so the exfiltration surface does not grow. A
  pushed commit can only leave the box via an agent's own Bash.
- **Residual risk, stated plainly:** in Auto mode the agent can already run
  `git push` or `curl` through Bash. Gating the phone-initiated routes protects
  only the phone path; it is not a sandbox.
- Hardening changes behavior for repos that rely on hooks/fsmonitor: daemon-run git
  ignores them by design.
- `git.test.ts`'s "commit/push 404" assertion becomes "stage/commit/branch exist,
  push is 404".
