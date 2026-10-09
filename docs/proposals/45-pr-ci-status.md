# 45 — Pull request & CI status

**Status:** implemented (daemon + app + tests 2026-10-07; on-device check pending)

Where does this chat's branch stand on GitHub? An open PR, its review and merge state, and
whether the checks pass — read-only, from the phone. Found by the gap analysis (Codex / Copilot /
Claude Code all surface PR + CI).

- **REST** ([session-rest.md](../protocols/session-rest.md#pull-request--ci-status)):
  `GET /sessions/:id/ci` (the session's own checkout — its worktree if it has one) and
  `GET /projects/:id/ci`. Always `200`: `{available:false, reason}` when there's nothing to show,
  else `{available:true, repo, branch, pr|null, checks[], checksState, runs[]}`. With a PR:
  number, title, state, url, draft, review decision, merge state and the checks of its rollup.
  Without one: the branch's latest 5 workflow runs. `checksState` is `passing | failing | pending
  | none`; a failure outranks pending, skipped checks are ignored.
- **Daemon** (`ci.ts`): runs exactly two *list* commands through `gh` — `pr list` and (no PR)
  `run list` — never create / comment / merge / push / auth. The repo comes from `origin` via the
  hardened `gitRun` and is accepted only for `github.com` in the forms git writes (strict regex;
  anything else is "not a GitHub repository" and `gh` is never called); the branch must match a
  conservative pattern and can't start with `-`; argv is an array with `GIT_*` scrubbed, prompts
  off, a 15 s timeout and a 1 MiB cap. Results are cached 30 s per checkout so a polling phone
  can't burn the API quota. `gh` failures map to a few fixed sentences (not installed, not signed
  in, not found, unreachable) — raw `gh` text (paths, hosts) is never returned. URLs must be
  `https`; text is clipped. Project / session paths must be inside `VIBE_PROJECT_ROOTS`.
- **App:** "Pull request & CI…" in the chat menu → `CiSheet`: repo · branch, the PR (state, review,
  merge status; tap to open on GitHub in the external browser), and each check or run with its
  outcome.
- **Credentials:** uses the server's existing `gh` login. Nothing about it reaches the phone, and
  the app can't change anything on GitHub.

Checked against the real GitHub on 2026-10-07: this repo's branch → PR #14 (open); another repo →
its latest CI runs.

Out of scope: creating a PR (needs push — ADR 0024 defers it), posting comments, re-running
checks, GitLab/other hosts, a push notification when CI finishes.

Tests: `vibe-daemon/src/ci.test.ts`, `app/test/ci_test.dart`.
