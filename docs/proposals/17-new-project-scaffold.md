# Proposal 17 — New project + foundations scaffold library

> Broader than the session-layered proposals here: this adds a small **new
> subsystem** (project creation + a scaffold library). On accept it graduates to
> an **ADR** (filesystem-write + git shell-out decision) and a **protocol** doc
> for the REST surface — not just a `prompts` tag. Listed here because this is
> where feature ideas get triaged.

## Why
Start a new project straight from the phone: create the directory **and** drop in
the foundation files (a generic `CLAUDE.md` + the `docs/` skeleton + conventions)
so every new project begins with the same guardrails this repo uses. A
**scaffold library** stores those foundations as reusable, editable templates —
the multi-file analogue of the `prompts` library.

## Sketch

### Scaffold = a stored set of files
New `scaffolds` table (separate from `prompts`: a prompt is one `body`; a scaffold
is many files):

```
scaffolds:
  id          TEXT PK
  name        TEXT NOT NULL
  description TEXT
  files_json  TEXT NOT NULL   -- JSON: [{ "path": "CLAUDE.md", "body": "..." }, ...]
  created_at  TEXT
  updated_at  TEXT
```

Seed one default — **"Foundations (generic)"** — a VibeMobile-specifics-stripped
copy of this repo's setup:

```
CLAUDE.md                 # behavioral guidelines (Karpathy 4), generic project-context stub
PLAN.md                   # stub headings (Goal / Architecture / Milestones)
.claude/docs-map.md       # routing-table conventions, empty rows
docs/README.md            # human index + "every unit of work gets a doc" convention
docs/proposals/README.md  # proposal lifecycle (idea→accepted→building→shipped)
docs/decisions/README.md  # ADR index + format
docs/protocols/.gitkeep
docs/spikes/.gitkeep
```

Empty dirs ship via `.gitkeep`. CRUD routes `/scaffolds` mirror `prompts.ts`
(create / list / get / put / delete, auth-gated, audited) so the library is
built and edited from the app.

### Create project
`POST /projects` (the route is currently GET-only):

```
POST /projects
{ "name": "railroad-saas", "root": "/home/user", "scaffold_id": "...", "git": true }
```

1. **Validate name** — allowlist `^[A-Za-z0-9][A-Za-z0-9._-]*$`, length cap,
   reject `..` / `/` / leading dot.
2. **Resolve + scope** — `root` must be one of `projectRoots()` (default = first
   root); `target = join(root, name)`; assert `pathInRoots(target)`; **refuse if
   it already exists** (no overwrite).
3. **mkdir** `target`.
4. **Write scaffold files** — for each `{path, body}`: normalize `path`, reject
   absolute / `..`, assert the resolved file stays inside `target`; `mkdir -p`
   parent; write. Token-substitute `{{project_name}}` / `{{date}}` on write.
5. **git** (when `git:true`) — `git init` → `git add -A` → `git commit` via
   `execFile` (args array, **no `shell`**, `cwd = target`). Set commit identity
   with `-c user.name/-c user.email` so it succeeds on a box with no global git
   config.
6. **Catalog + audit** — upsert into `projects`, log `project.create`, return the
   new project row.

## Impact
- **Schema:** new `scaffolds` table + one seed row. No change to existing tables.
- **REST:** `POST /projects` (new verb on existing path) + `/scaffolds` CRUD.
  Document in a new `docs/protocols/project-rest.md` (or extend `session-rest.md`).
- **Server — new write surface:** first filesystem `mkdir`/write and first `git`
  shell-out **outside** the PTY/SDK engines. The scanner has been read-only by
  design; this changes that. → **security.md** gets a new row; the write/shell-out
  call warrants an **ADR**.
- **Client:** new-project screen (name + root + scaffold picker + git toggle);
  scaffold-library editor (reuse the prompt-library list/edit UI). Client work can
  be a follow-up after the daemon lands.

## Security (the crux — PLAN §5)
This is the first route that **creates files and runs git** on the server.
- **Name allowlist** + length cap; reject `..`, `/`, absolute, leading dot.
- **Target inside `projectRoots()`** via `pathInRoots` (lift it out of
  `sessions.ts` to a shared module so create + session share one guard).
- **Per-file containment:** every scaffold `path` normalized and asserted inside
  `target` before write — a malicious/edited scaffold can't escape via `../`.
- **No overwrite:** refuse if `target` exists; refuse if a scaffold file would
  clobber.
- **Caps:** max files per scaffold + max total bytes (mirror the attachment cap,
  proposal 16 / security.md #8).
- **git via `execFile`** (array args, no shell string) → no command injection;
  `cwd` scoped to `target`; nothing from the request reaches a shell.
- **Audit + rate-limit:** `events` row per create; rate-limit `POST /projects`.

## Decisions (resolved)
- **Root:** land new projects in `projectRoots()[0]` — `/home/user`, alongside the
  existing `my-project` / `railroad-saas` / `construction-platform`. Only one
  root is configured, so `root` is optional in the request and defaults there; if
  sent it must still be an allowed root. No picker UI needed now.
- **git identity:** commit as the **paired device** —
  `git -c user.name="<device.name>" -c user.email="<device.id>@vibe.local" commit`
  — so the audit trail shows which device created the project.
- **Var substitution:** only `{{project_name}}` and `{{date}}`, token-replaced on
  write. No `vars_json` engine for scaffolds now (speculative — Simplicity First).
