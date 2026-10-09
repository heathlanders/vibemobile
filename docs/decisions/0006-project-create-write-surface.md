# ADR 0006 — Project creation write surface (mkdir + scaffold + git)

**Status:** Accepted (2026-06-21)

## Context

Proposal 17 lets the user create a new project from the phone: make a directory
under a project root, drop in a foundation scaffold (CLAUDE.md + docs skeleton),
and `git init` + commit it. This is the daemon's **first filesystem write and
first `git` shell-out outside the PTY/SDK engines** — until now the scanner was
read-only by design and only the PTY/Agent-SDK subprocesses touched disk or
spawned (`scanner.ts`, `security.md` #7). A create route takes a client-supplied
project name and a client-editable scaffold (arbitrary `{path, body}` files) and
turns them into real files and a subprocess. That is exactly the surface `PLAN.md
§5` says gets extra scrutiny, so the decision is recorded here.

## Decision

Add `POST /projects` (`projects.ts`) with every input validated before anything
touches disk:

- **Name** is a single path segment matched against an allowlist
  `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$` — no `/`, no `..`, no leading dot, capped
  at 64 chars.
- **Target is scoped** to `projectRoots()` via the shared `pathInRoots` guard
  (lifted out of `sessions.ts` to `paths.ts` so session-spawn and project-create
  share one rule). Root defaults to `projectRoots()[0]`; a client-sent root must
  equal a configured root, not a subdir.
- **No overwrite:** refuse (`409`) if the target exists; each scaffold file is
  written with `wx` (fail-if-exists).
- **Per-file containment** (`scaffold-files.ts`): every scaffold path is
  normalized and asserted to stay inside the target, rejecting absolute paths and
  any `..` segment. Validated both on store (scaffold CRUD) **and** re-checked on
  write — a row could predate a rule, and write is where a bad path escapes.
- **Caps:** ≤200 files, ≤1 MB total per scaffold (mirrors the attachment caps,
  ADR-less security.md #8).
- **git via `execFile`** — array args, never a shell string, `cwd` scoped to the
  target → no command injection. The commit is attributed to the paired device
  (`-c user.name=<device.name> -c user.email=<device.id>@vibe.local`) so the
  audit trail shows who created it.
- **Rollback + audit:** any failure after `mkdir` removes the partial dir; every
  outcome logs a `project.create` / `project.create.fail` event. The route is
  rate-limited (10/min).

Scaffolds are stored in a new `scaffolds` table (`files_json`), seeded once with
a generic "Foundations" skeleton, and edited via `/scaffolds` CRUD — the
multi-file analogue of the `prompts` library.

## Consequences

- The daemon now writes files and runs `git`. The blast radius is bounded to
  `projectRoots()` by `pathInRoots` and to non-existing targets by the
  no-overwrite rule; nothing client-supplied reaches a shell string.
- `pathInRoots` is now shared (`paths.ts`); `sessions.ts` imports it instead of
  its private copy — one guard to audit, not two.
- Adds a `git` runtime dependency for the create path (already present for dev).
  A box with no git breaks create-with-commit only; bare mkdir still works.
- `git`-less or empty creates init-only (no commit) rather than failing on
  "nothing to commit".
- Tracked as security.md #9. REST shape documented alongside `session-rest.md`;
  client UI (new-project screen + scaffold-library editor) was the follow-up and
  has shipped (`new_project_screen.dart`, `scaffold_list_screen.dart`,
  `scaffold_edit_screen.dart`; proposal 17).
- Alternative considered: a filesystem template dir on the server instead of a DB
  table. Rejected — not editable from the app, and the prompt library already set
  the DB-backed, CRUD-over-REST precedent.
