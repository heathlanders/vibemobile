# ADR 0011 — Git surface: read-only status now, write behind an opt-in later

**Status:** Accepted (2026-08-08). Read-only status **shipped**; commit/push
specified here but **not built**.

## Context

The project cockpit (proposal 23) wants working-tree state on the phone: which
branch, how many changed files, ahead/behind. The obvious next step — commit and
push from the phone — is not an incremental extension of it, and this ADR exists
to keep those two apart.

[ADR 0006](0006-project-create-write-surface.md) already allows a `git` shell-out,
but only in a **freshly created, previously non-existent, empty** directory. That
bounded the blast radius to a dir the request itself had just made. Running git in
an **existing repo with real history and the server's real remote credentials** is
a different risk class:

1. **Push exfiltrates.** `git push` sends repository contents to a remote using
   whatever credentials the server holds (SSH agent, credential helper). A phone
   tap becomes a network egress of source code — a new *kind* of action, not a
   bigger version of an existing one.
2. **`git add -A` in a live repo** stages whatever is on disk, including a `.env`
   an agent wrote thirty seconds earlier. Committing that locally is recoverable;
   pushing it is not.
3. **The commit message is free text from the phone** — the first client-supplied
   string that would reach a `git` argv in an existing repo.
4. **Ref/remote names** are exactly the kind of thing that looks convenient to
   parameterise and is impossible to bound afterwards.

## Decision

### Shipped now — read-only

`GET /projects/:id/git-status` (`git.ts`, new module):

- project row → `pathInRoots` (`403` outside roots, `404` unknown project);
- `execFile("git", ["status","--porcelain=v1","-b"], {cwd})` — **array args, never
  a shell string**, 5 s timeout, 1 MiB output cap;
- returns `{repo, branch, ahead, behind, clean, files[], truncated}`; failure of
  any kind (not a repo, git missing, timeout) degrades to `repo:false` rather
  than erroring;
- files capped at 200 with an explicit `truncated` flag — no silent cut.

`scanner.ts` is **not** touched: it is documented as no-shell-out by design, and
that guarantee is worth more than the convenience of putting git status there.

A regression test asserts `POST /projects/:id/git/commit` and `.../git/push`
return `404` — the write routes do not exist yet, and the test fails loudly if
someone adds them without revisiting this ADR.

### Specified, not built — write

If commit/push is wanted later, this is the shape it must take:

- `POST /projects/:id/git/commit {message}` — `git add -A`, then commit with
  `-c user.name=<device.name> -c user.email=<device.id>@vibe.local` exactly as
  ADR 0006 attributes. `execFile` array args only; message ≤500 chars and a
  leading `-` rejected (or passed after `--`) so it can't be read as a flag;
  audited `git.commit`; rate-limited.
- `POST /projects/:id/git/push` — **gated behind `VIBE_GIT_PUSH=1`, default OFF**
  (`403` otherwise). No client-supplied remote or ref: push the current branch to
  its configured upstream, or `400`. Never `--force`. Audited `git.push`.
- **No credential ever accepted over the wire.** If the server's git can't
  authenticate, the push fails — the daemon must not take a token or password.

## Consequences

- The phone can see whether a project is dirty without any new write or egress
  path. That is most of the cockpit value at nearly none of the risk.
- The daemon now shells out to `git` outside project creation. Bounded by
  `pathInRoots`, a timeout, an output cap, and the absence of any client-supplied
  argument — the only variable is `cwd`, which is a validated project path.
- A box without `git`, or a project that isn't a repo, simply reports
  `repo:false`; the client hides the strip entirely, so nothing new appears for
  non-repo projects.
- Tracked as `security.md` #15.
- Alternative considered: parse `.git` files directly to avoid the shell-out
  (the scanner already reads `.git/HEAD` for the branch name). Rejected —
  reimplementing index/worktree comparison is far more code and far more ways to
  be wrong than one fixed-argv `git status`.
