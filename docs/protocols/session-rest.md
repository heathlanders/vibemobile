# Protocol — session lifecycle (REST)

Session **creation and teardown** live on REST; the WebSocket endpoints
(`/pty/:id`, `/session/:id`) are **attach-only**. This split is what makes
terminal reattach clean: a reconnecting socket always attaches an existing
session, never races to create one.

Builds on / required by:
[reattach.md](./reattach.md) ·
[ADR 0004 tmux-backed PTY](../decisions/0004-tmux-backed-pty.md) ·
`PLAN.md §3` (data model), `§4` (flows).

## Why creation moved off the WebSocket

The M0 spike spawned the shell on WS connect (`serve-pty.ts:20`). That conflates
"open a session" with "attach to it" — a dropped-then-reconnecting client would
re-create instead of resume. Splitting them gives:

- **Attach-only WS** → reconnect = re-attach, with no "is this first-open?" state.
- **Honest `4404`** → attaching a session whose shell exited is an error the
  client can surface ("session ended"), not a silent fresh shell (reattach.md).
- A first-class `sessions` row exists **before** any socket — the dashboard can
  list sessions that have no client attached.

## Endpoints

All require the device bearer token (`PLAN.md §2C`, M1). Daemon binds localhost;
reached over the tailnet via `tailscale serve` (ADR 0005). Base:
`https://<machine>.<tailnet>.ts.net`.

| Method | Path | Purpose |
|--------|------|---------|
| `POST` | `/sessions` | Create a session (terminal or claude) |
| `GET`  | `/models` | Selectable models for the picker (ADR 0007) |
| `GET`  | `/sessions?project_id=…` | List sessions (dashboard) |
| `GET`  | `/sessions/:id` | One session's metadata + status |
| `PATCH` | `/sessions/:id` | Rename / retag ([proposal 12](../proposals/12-session-rename-tags.md)). A `title` PATCH also pins it against the auto-titler |
| `DELETE` | `/sessions/:id` | End + remove a session |
| `POST` | `/sessions/prune` | Bulk-delete a project's `stale` rows: `{project_id, older_than_days?}` → `{deleted}` (plus `worktreesKept` when a stale worktree session had work to keep, ADR 0022). See [External sessions](#external-sessions-discovery) |
| `POST` | `/sessions/:id/attachments` | Upload an image blob (raw image body) for a `kind=claude` turn → `{attachmentId, mediaType}` |
| `GET`  | `/attachments/:id` | Fetch a stored blob (client thumbnail / history redraw) |
| `GET`  | `/sessions/:id/file-edits` | Changed-files list for the session ([proposal 20](../proposals/20-session-file-viewer.md)) |
| `GET`  | `/sessions/:id/file-edits/diff?path=` | Per-file unified diffs of the session's edits |
| `GET`  | `/sessions/:id/file?path=` | Current content of an edited file (full-file view) |
| `GET`  | `/sessions/:id/tree?q=&limit=` | File **names** under the session's project, for `@file` autocomplete ([ADR 0010](../decisions/0010-session-tree-read-surface.md)) |
| `GET`  | `/sessions/:id/image?path=` | Raw bytes of an **image** file in the session's project, for chat previews ([ADR 0021](../decisions/0021-session-image-read-surface.md)) |
| `GET`  | `/sessions/:id/pending` | Waiting `permission_request` / `user_dialog` frames + `title` — what a push renders ([ADR 0013](../decisions/0013-push-notifications.md)) |
| `POST` | `/sessions/:id/permission` | `{toolUseID, allow}` — answer an approval without a WS attach. `204`, or `410` if no longer pending |
| `POST` | `/sessions/:id/dialog` | `{dialogId, completed, result?}` — answer a question without a WS attach. `204`, or `410` |
| `GET`  | `/devices` | Paired devices; the caller's own row is flagged `current` |
| `POST` | `/devices/fcm` | `{token}` — register the caller's FCM token for pushes (ADR 0013) |
| `DELETE` | `/devices/:id` | Revoke a device's token (security.md #4) |
| `GET`  | `/events?limit=&before=&kind=` | Audit log, newest first ([proposal 23](../proposals/23-project-cockpit.md), security.md #14). **Read-only** |
| `GET`  | `/projects/:id/git-status` | Working-tree status: `{repo, branch, ahead, behind, clean, files[], truncated}` ([ADR 0011](../decisions/0011-git-surface.md)). **Read-only** — no commit/push route exists |
| `GET`  | `/projects/:id/notes` | Project notes/TODOs ([proposal 31](../proposals/31-project-notes.md)): open items oldest first, then done items most recently ticked first |
| `POST` | `/projects/:id/notes` | `{text}` (1–4000 chars, trimmed) → `201` note; `404` unknown project |
| `PUT`  | `/notes/:id` | Partial `{text?, done?}` → the updated note |
| `DELETE` | `/notes/:id` | Delete a note. `204`, idempotent |

### Swarm tasks

[Proposal 65](../proposals/65-swarm-tasks-and-leases.md). Bearer-gated, shaped like notes. A task has
`{id, project_id, title, body, scope[], deps[], state, session_id, created_at, updated_at}`;
`state` is `ready | running | review | done`.

| Method | Path | Notes |
|--------|------|-------|
| `GET`  | `/projects/:id/tasks` | The project's tasks, oldest first; `404` unknown project |
| `POST` | `/projects/:id/tasks` | `{title, body?, scope?, deps?}` -> `201` task in `ready`. Title 1-200 chars, body <= 20000, `deps` are task ids of this project. `scope` is normalised (repo-relative prefixes; `..`, leading `/`, `.git` refused; <= 50 entries of <= 512 chars); `400` on any violation |
| `PUT`  | `/tasks/:id` | Partial `{title?, body?, scope?, deps?, state?}`. Fields only while `ready` (`409` otherwise). `state` may be set to `ready` (from any state; clears `session_id`, lifting the lease) or `done` (from `review` only, else `409`) |
| `DELETE` | `/tasks/:id` | `204`, idempotent |
| `POST` | `/tasks/:id/dispatch` | Creates a worktree Claude session (same path as `POST /sessions`, so caps apply), sets the task `running`, and starts the first turn server-side with no client attached. -> `{task, session_id}`. `409` with the blocker named: task not `ready`, a dependency not `done`, an overlapping `running`/`review` task, or `VIBE_SWARM_MAX` (default 3) running tasks. Session-creation failures pass through (`429`, `507`, `400`) and leave the task `ready` |

Audit kinds: `task.create`, `task.update`, `task.delete`, `task.dispatch` (REST); `task.claim`,
`task.complete`, `lease.deny` (sessions). Peer tools for the same list are in
[proposal 30](../proposals/30-session-peer-tools.md#swarm-task-tools-proposal-65).

The byte/event channels stay on WS, unchanged: `WS /pty/:id` (terminal,
[pty-ws.md](./pty-ws.md)), `WS /session/:id` (claude, Agent SDK).

### Concurrency caps

`POST /sessions` rejects with `429` once the host is full, counted over `live`
rows of the kind (DELETE frees a slot; the idle reaper does not):

| Env | Kind | Default |
|-----|------|---------|
| `VIBE_MAX_CLAUDE` | claude | 6 (was 4; raised for the multi-chat grid, [proposal 19](../proposals/19-multi-chat-grid.md)) |
| `VIBE_MAX_TERMINAL` | terminal | 8 |

## POST /sessions

Request:

```json
{ "project_id": "p_…", "kind": "terminal", "title": "build logs" }
```

`kind` ∈ `terminal` | `claude`. `title` optional — when omitted the daemon
auto-names a claude session from its first turn ([ADR 0009](../decisions/0009-auto-session-title.md))
and records that in `sessions.title_auto`; a title passed here, or set later by
`PATCH /sessions/:id`, clears that flag and is never overwritten.
`model` (optional string, **claude only**, ADR 0007) selects the upstream model
routed by the local gateway; ignored for `terminal`, and null = the gateway/CLI
default. Any string is accepted — the gateway rejects unknown ids at runtime (no
coupling to `/models`). The effective model is also reported back to the phone on
attach via the `init` frame ([claude-ws.md](./claude-ws.md)).
`mode` (optional, **claude only**, [proposal 25](../proposals/25-permission-modes.md))
is the session's starting mode: `'ask'` | `'auto'` | `'plan'`, anything else (or
any `mode` on a terminal session) → `400`. Omitted = the daemon default (`auto`).
Stored in `sessions.mode`; afterwards it changes only via the `mode` WS frame.
`worktree` (optional boolean, **Claude engine only**, [ADR 0022](../decisions/0022-worktree-sessions.md))
runs the session in its own git worktree, `<project>/.vibe-worktrees/<id>` on branch
`vibe/<id>`, forked from the project's current `HEAD`. `400` for a terminal, a
native-provider model, a non-boolean, or a project that isn't a git repo with a commit
(a generic message — git's own stderr is never echoed); `429` past `VIBE_MAX_WORKTREES`
(default 12, counting kept ones). Persisted as `sessions.worktree_path` /
`worktree_branch` / `base_ref`; the Agent SDK then runs with that path as `cwd`, and
every per-session file route (`/file-edits`, `/tree`, `/image`, rewind) is rooted
there. Auto-mode file scope is the checkout + `~/.claude` only. Audited
`session.worktree.create`.

Server, by kind:

- **terminal** — create the detached tmux session, then insert the row:
  ```
  tmux -L vibe new-session -d -s vibe-<id> -x 80 -y 24 \; \
       set -g history-limit 10000 \; setw -g aggressive-resize on
  ```
  cwd = the project's `path`. The shell is now live and detached, waiting for
  `WS /pty/:id` to attach (reattach.md).
- **claude** — insert the row only. No Agent SDK process yet; it starts on
  `WS /session/:id` attach, and the real `claude_session_id` is captured from
  the SDK `init` event (`spikes/M0-spike1`) and written back for resume.

Response `201`:

```json
{ "id": "s_…", "project_id": "p_…", "kind": "terminal",
  "title": "build logs", "status": "live", "created_at": "2026-06-09T…Z",
  "model": null, "worktree_branch": null }
```

`worktree_branch` is `vibe/<id>` when `worktree:true` was honoured, else `null`.

## GET /models

Returns the **non-secret** model registry for the picker (ADR 0007). The list is
**auto-updating**: in the default direct-Anthropic mode the daemon pulls the live
Anthropic Models API (`GET /v1/models`, authed with the same CLI-login OAuth token
`/usage` reuses) so new Anthropic releases appear with no code or config change,
then merges any operator `VIBE_GATEWAY_MODELS` overrides (JSON `[{id,label,provider}]`
— same id overrides the label/provider, new ids are appended). The live result is
cached (1 h TTL) and **fails soft** to a small static fallback (current Opus/Sonnet/
Haiku) if the API is unreachable. In gateway mode (`VIBE_GATEWAY_URL` set) the
operator `VIBE_GATEWAY_MODELS` list is authoritative — its `provider` values drive
engine routing — and the daemon never auto-fetches; it degrades to a single
`default` entry when that env is unset. Never exposes provider keys.

```json
{ "models": [ { "id": "claude-opus-4-8", "label": "Opus 4.8", "provider": "anthropic" },
              { "id": "gpt-4o", "label": "GPT-4o", "provider": "openai" } ] }
```

**Native providers + discovery (ADR 0016).** In direct mode the list also holds
every configured native provider's models, discovered live and namespaced
`provider:model` (`openai:gpt-5`, `google:gemini-2.5-pro`, `ollama:llama3:8b`).
Entries may carry optional hints from the operator models file
(`~/.config/vibe-daemon/models.json`) or OpenRouter: `price` (`{in,out}` USD per
1M tokens), `context` (tokens), `tags` (strings).

```json
{ "id": "openai:gpt-5", "label": "gpt-5", "provider": "openai",
  "price": { "in": 1.25, "out": 10 }, "context": 400000, "tags": ["coding"] }
```

## GET /projects

Scans `VIBE_PROJECT_ROOTS` (default `/home/user`), syncs the catalog and returns
it, newest activity first (`scanner.ts`, filesystem only).
- **What counts as a project (2026-10-06):** an immediate child dir that's a git
  checkout (a `.git` dir, or a worktree's `.git` file) or has `package.json`,
  `pubspec.yaml` or `composer.json`. Scratch dirs, `Downloads`, SDKs without git
  and the like are skipped.
- **`VIBE_PROJECT_IGNORE`:** comma-separated dir names to hide anyway (this box
  sets `flutter`, the SDK checkout).
- **Pruning:** a rescan deletes rows whose dir vanished or no longer qualifies.
  Rows that have sessions, project-scoped prompts or notes are kept, because
  deleting them would cascade.
- A git-less `POST /projects` with no marker files is still returned and listed
  right after creation. It drops out on a later scan unless it has a session by
  then.

## GET /spend

Token/cost ledger aggregates (ADR 0017). `group` ∈ `model` (default) |
`project` | `provider` | `day`, and `days` is 1–365 (default 30).

```json
{ "group": "model", "days": 30, "since": "…",
  "totals": { "turns": 40, "input": 20000, "output": 30000, "cacheRead": 900000, "cacheWrite": 80000, "cost": 6.2 },
  "rows": [ { "key": "claude-opus-4-8", "label": null, "turns": 25, "…": "same sums" } ] }
```

`label` is the project name when grouped by project. `input` counts uncached
tokens only. Rows are sorted by cost, except by-day rows, which are
chronological. Project rows also carry `claudeMdBytes`: the size of the
project's root `CLAUDE.md`, or null if there is none (a server-side `stat`; the
absolute path is not returned). It feeds the CLAUDE.md-size saving tip.

## GET /spend/session/:id

One session's all-time ledger (ADR 0017), for the chat menu's **Token usage**
sheet: `{ "totals": {…same sums}, "rows": [ one per model ] }`, rows by cost.
An unknown id returns zero totals and no rows (the id is only a bound SQL
parameter). Read-only, bearer-gated.

## GET /usage/plan

Max-plan meters outside any chat (ADR 0020). This is the same cached value as
the chat `usage` frame (`usage.ts`, 5-minute TTL), so polling never reaches
upstream more often than that.

```json
{ "usage": { "session": { "label": "Session", "pct": 45, "resetsAt": "…", "severity": "normal" },
             "weekly": [ { "label": "All models", "pct": 12, "resetsAt": "…" } ] },
  "fetchedAt": "2026-10-06T12:00:00.000Z" }
```

`usage` and `fetchedAt` are null until the daemon has one good fetch (they stay
null in gateway mode).

## GET /system

Read-only server health (ADR 0019). The client polls it about every 3 seconds.

```json
{ "hostname": "snf", "uptimeSec": 624886, "load": [3.2, 3.1, 2.4],
  "cpu": { "cores": 4, "pct": 26.9, "tempC": 41 },
  "mem": { "total": 16705454080, "available": 4311351296, "swapTotal": 4294963200, "swapFree": 180224 },
  "disks": [ { "path": "/", "total": 249322430464, "free": 19291127808 } ],
  "net": [ { "iface": "eno1", "rx": 19506957456, "tx": 14664075567 } ],
  "gpus": [ { "name": "NVIDIA GeForce GTX 1070", "utilPct": 0, "memUsedMb": 2, "memTotalMb": 8192, "tempC": 51 } ],
  "top": [ { "pid": 2586468, "name": "postgres", "cpuPct": 0, "rssKb": 2294372 } ],
  "services": [ { "name": "tailscaled", "scope": "system", "state": "active" } ],
  "diagnostics": {
    "tailscale": { "available": true, "state": "Running", "dnsName": "box.tailnet.ts.net", "serving": true },
    "node": { "daemon": "v18.20.8", "shell": "v20.20.2", "mismatch": true },
    "daemon": { "uptimeSec": 5400, "sdkVersion": "0.3.291", "fcm": true } },
  "alerts": [ { "key": "disk:/", "message": "Disk / 92% full" } ] }
```

`diagnostics` (proposal 29) is refreshed at most every 5 minutes.
- `tailscale.serving`: some `tailscale serve` handler still proxies to
  `127.0.0.1`/`localhost` on the daemon port.
- `node.shell`: what a fresh interactive terminal's `node -v` prints.
- `tailscale` alert: the backend state isn't `Running`.
- `tailscale-serve` alert: the state is `Running` but nothing forwards to the
  daemon.

Byte fields are bytes; `rssKb` is KiB. `cpu.tempC` is `null` when the box has no
CPU hwmon sensor. `net` holds byte counters since boot for real interfaces
(`lo`, `veth*`, `br-*`, `docker*`, `virbr*` dropped); the client turns two polls
into rates.

## GET /presets

Agent CLIs (ADR 0016) installed on the server, ids + labels only:
`{ "presets": [ { "id": "codex", "label": "Codex CLI" } ] }`. Start one with
`POST /sessions { "kind": "terminal", "preset": "codex" }`. The server types its
fixed command into a new tmux shell, and the session title defaults to the
label. You get a 400 for an unknown or non-string preset, a preset on a
`claude` session, or a CLI that isn't installed.

The `id` is server-assigned and **stable for the session's life** — the client
stores it and reuses it for every WS (re)attach (reattach.md: a new id orphans
the tmux session).

## DELETE /sessions/:id

Tears the session down for good (distinct from a WS close, which only detaches):

- terminal → `tmux -L vibe kill-session -t vibe-<id>`
- claude → stop the Agent SDK process if running
- delete the `sessions` row (cascade `messages`)

A worktree session's checkout is removed **only if nothing would be lost** — clean
tree, no commits beyond `base_ref`, never `--force` (a hand-deleted directory is
just pruned). Otherwise it stays on disk and the response is `200`
`{ "kept": true, "path": "…", "branch": "vibe/s_…", "reason": "dirty"|"commits"|"error" }`
(the session row is deleted either way). Audited `session.worktree.remove` /
`session.worktree.kept`.

Response `204` (or the `200` above). Idempotent: deleting an already-gone session is `204`, not `404`.

## Attachments (image input, claude sessions)

`POST /sessions/:id/attachments` (`kind=claude` only) takes the **raw image bytes
as the request body** (not multipart — the daemon buffers them with a per-parser
`bodyLimit`), validates and stores it, and returns a ref the `user` WS frame
carries (`images:[attachmentId]` — [claude-ws.md](./claude-ws.md#attachments-image-input)).
Why REST not WS: a multi-MB blob doesn't belong in the JSON event stream; this
keeps the same lifecycle-on-REST / stream-on-WS split as session creation.

- **Validate by magic bytes**, not extension or client `Content-Type`: png/jpeg/
  webp/gif only. Reject over the size cap **before** buffering the whole body.
- Stored as a **SQLite BLOB** keyed by a **server-minted random id** — no
  client-supplied path (traversal), no filesystem write surface at all.
- `messages` rows reference the attachmentId; blobs are deleted with the session on
  `DELETE /sessions/:id` (the `attachments` row cascades on the FK).
- `GET /attachments/:id` serves the blob (bearer-gated, same as every route) for
  thumbnail and history redraw.
- Audit each upload to `events` (size, mediaType, session). Rejections are
  audited as `attachment.reject` (`<session>:<too_large|unsupported_type>:<bytes>`),
  including the parser-level `bodyLimit` 413 (route `errorHandler`).
- **Client normalizes before upload** (`chat/domain/image_normalize.dart`): any
  non-allowlisted format or >1568px image is decoded by the engine, downscaled,
  and re-encoded PNG. Needed because `Pasteboard.image` on Windows returns BMP
  (→ 415 before 2026-10-06). The 415/413 error shows `(HTTP <code>)` in the
  snackbar and is written to the client log (Settings → Copy logs).

## File edits (session file viewer)

Post-hoc, git-style view of what a claude session changed
([proposal 20](../proposals/20-session-file-viewer.md)). Reconstructed from the
persisted `messages.tool_json` rows — works for live **and** past sessions, no
WS change.

- `GET /sessions/:id/file-edits` →
  `[{path, relPath, edits, adds, dels, written, lastTs}]` — Edit/Write/MultiEdit
  ops grouped by `input.file_path`, `isError` ops skipped. `written` = a `Write`
  overwrote/created the file. DB-only, no filesystem access.
- `GET /sessions/:id/file-edits/diff?path=<abs>` →
  `{path, relPath, edits:[{ts, tool, replaceAll, diff, adds, dels, truncated}]}`
  — one unified-diff section per edit in ts order (edits are **not** chained:
  they're disjoint snippets of an unknown full file). `Write` renders as
  all-additions. Cuts append a visible `… +N lines truncated` marker — never
  silent. DB-only.
- `GET /sessions/:id/file?path=<abs>` →
  `{path, relPath, content, size, truncated}` — the only filesystem read.
  Guards in order: path must be in the session's own **edit set** (capability,
  not a file browser) → `realpath` + `pathInRoots` re-check → regular file →
  size cap (`VIBE_MAX_FILEVIEW_BYTES`, default 512 KiB) → NUL sniff ⇒ `415`.
  Every read audited to `events` (`file.read`).

## Session tree (`@file` autocomplete)

`GET /sessions/:id/tree?q=<substr>&limit=<n>` →
`{root, files:[{relPath}], truncated}` — file **names** under the session's
project ([ADR 0010](../decisions/0010-session-tree-read-surface.md),
`security.md` #13). Names only: content still needs the edit-set capability of
`GET /sessions/:id/file` above.

Guards: project path in `pathInRoots` (else `403`; unknown session or session
without a project ⇒ `404`) → pure `node:fs` walk, no shell-out → symlinks skipped
(never followed) → dotdirs + `node_modules`/`build`/`dist`/`target`/`vendor`/
`coverage` excluded → ≤5000 entries walked, `limit` clamped to 50 → `truncated`
set whenever anything was cut (never silent). Audited as `session.tree`,
rate-limited 30/min.

The daemon does **not** resolve a mention: the client inserts the literal
`@lib/core/theme.dart` text into the `user` frame and Claude reads it with its own
gated Read tool. No wire change.

## Session image (chat preview)

`GET /sessions/:id/image?path=<rel-or-abs>` → raw image bytes, `Content-Type`
from the sniff, `Cache-Control: no-store`
([ADR 0021](../decisions/0021-session-image-read-surface.md), `security.md` #23,
[proposal 33](../proposals/33-chat-images.md)). The client previews image paths
Claude mentions in a reply.

Guards: session with a project (else `404`; no `path` ⇒ `400`) → relative path
resolved against the project root; root and target `realpath`'d, target must be
inside **this session's** project (sibling project, outside path, symlink escape
⇒ `403`) + `pathInRoots` → regular file (else `404`) → ≤ `VIBE_MAX_ATTACH_BYTES`
(else `413`) → bytes must sniff png/jpeg/webp/gif (else `415`, whatever the
extension). Audited as `file.image`, rate-limited 120/min.

## Rewind (file checkpoints)

`POST /sessions/:id/rewind {messageId, dryRun?}` undoes a user message's file edits
**and everything after** ([ADR 0023](../decisions/0023-checkpoint-rewind.md),
[M8 spike](../spikes/M8-spike-checkpoint-rewind.md), `security.md` #24). `messageId`
is a daemon `messages.id` (from the `history` frame) of a *user* message in this
session. `dryRun` defaults to **true**; send `false` to really rewind.

Response `200`: `{canRewind, dryRun, filesChanged[], insertions?, deletions?, skippedLinks?}`
— `filesChanged` are project-relative (absolute if outside the project but inside
another root). A real run returns the file list from its dry run (the SDK returns none).
`canRewind:false` + `error` when the SDK refuses.

Errors: `400` bad body · `404` unknown session / not a claude session / message not a
user row of this session / row has no checkpoint uuid (older turns) · `409` session
not running (open the chat), a turn is running, or a rewind already in flight · `403`
the SDK's file list reaches outside the project roots (nothing is rewound) · `400`
engine has no rewind (native). Audited `session.rewind` / `session.rewind.dry` /
`session.rewind.denied`. Edits made through **Bash** are not tracked and not undone.

## File browser

`GET /sessions/:id/browse?path=<folder>` and `GET /sessions/:id/browse/file?path=<file>`
([proposal 46](../proposals/46-file-browser.md), `security.md` #31). Bearer-gated, **read-only**,
90/min. Paths are relative to the session's checkout (its worktree if it has one); `path` omitted =
the root.

- Folder → `{path, entries:[{name, type:"dir"|"file"|"link", size?, readable}], truncated}` — folders
  first, then files, case-insensitive; max 500 entries. `.git` is never listed. `readable:false` marks
  secret-looking files and links that leave the project (listed, not openable).
- File → `{path, size, truncated, content}`; text only, first 256 KiB.
- Errors: `400` bad/NUL/over-long path, a file where a folder is expected or vice versa · `403` outside
  the project (**identical whether or not the target exists**), `.git`, or a secret-looking file ·
  `404` not found / session unknown · `415` binary. Successful reads are audited `file.browse`.

## Project files

[ADR 0030](../decisions/0030-project-file-writes.md), [proposal 59](../proposals/59-project-files-transfer.md),
`security.md` #33. Every route exists under **both** `/projects/:id/files…` (the project path) and
`/sessions/:id/files…` (the session's worktree, else the project path; any session kind). Bearer-gated.
`path` is relative to that root; same confinement as the [file browser](#file-browser) (`403` outside the
project, identical whether or not the target exists; `.git` and secret-looking files refused for read,
download and write). Error bodies are `{error}` with a short fixed sentence, never a path.

- `GET …/files?path=` → folder listing, same shape as the browser. 90/min.
- `GET …/files/text?path=` → `{path, content, sha, mtime, size}`; `sha` = SHA-256 hex of the bytes,
  `mtime` ISO-8601. `413` over `VIBE_MAX_EDIT_BYTES` (never truncated), `415` binary (NUL in the first
  8 KiB) or not valid UTF-8, `400` not a regular file. A UTF-8 BOM is kept in `content`. Audited `file.read`. 90/min.
- `PUT …/files/text` JSON `{path, content, baseSha}` (save an existing file) or `{path, content, create:true}`
  (new file); exactly one of the two. → `{path, sha, mtime, size}`. `409 {error, sha}` when the current bytes
  don't hash to `baseSha` (`sha` is the current one); `409` when `create` and the name exists (a dangling
  symlink counts as existing); `413` content over the edit cap (UTF-8 bytes); `404` missing file/folder
  (folders are never created); `400` bad name (empty, `.`/`..`, `\`, control characters, over 255 bytes) or body; `403` `.git`
  or secret-looking name. Audited `file.write`. 30/min.
- `GET …/files/raw?path=` → the bytes, `Content-Type: application/octet-stream`, `Content-Length`,
  `Content-Disposition: attachment; filename="<ascii fallback>"; filename*=UTF-8''<name>`,
  `X-Content-Type-Options: nosniff`. `413` over `VIBE_MAX_DOWNLOAD_BYTES`. Audited `file.download`. 30/min.
- `PUT …/files/raw?path=&overwrite=0|1` body `application/octet-stream`, streamed to disk (never buffered
  whole) → `{path, sha, size}`. `409` target exists and `overwrite` isn't `1`; `404` folder missing;
  `413` over `VIBE_MAX_UPLOAD_BYTES` (also when `Content-Length` says so up front; temp file removed,
  audited `file.upload_reject`); `415` any other content type; `507` disk-guard refused (ADR 0025 message); `400` interrupted upload.
  Audited `file.upload`. 30/min. These routes use their own content-type parser, separate from the
  5 MiB image-attachment one.

Writes are atomic (temp file `.<name>.vibe-<hex>.tmp` in the target's real folder, fsync, rename), keep
the existing file's mode (new files 0644), and write through an in-root symlink to its real file. One
write at a time per project. Audit detail is `<projects|sessions>:<id>:<bytes>:<path>` (path last; it may contain `:`).

| Env var | Default | Meaning |
| --- | --- | --- |
| `VIBE_MAX_EDIT_BYTES` | 2 MiB | largest text file readable/savable through `files/text` |
| `VIBE_MAX_DOWNLOAD_BYTES` | 200 MiB | largest `files/raw` download |
| `VIBE_MAX_UPLOAD_BYTES` | 100 MiB | largest `files/raw` upload |

## Pull request & CI status

`GET /sessions/:id/ci` and `GET /projects/:id/ci` ([proposal 45](../proposals/45-pr-ci-status.md),
`security.md` #30). Bearer-gated, 30/min, **read-only**, cached 30 s per checkout. Always `200`
for a known project/session (`404` unknown, `403` outside the allowed roots):

- `{available:false, reason}` — origin isn't a GitHub repo, detached HEAD, not a git repo, `gh`
  missing / not signed in, repo not found, GitHub unreachable. `reason` is one of a few fixed sentences.
- `{available:true, repo:"owner/name", branch, pr, checks, checksState, runs}` — `pr` is `null` or
  `{number, title, state, url, isDraft, review, mergeState}`; `checks[]` / `runs[]` are
  `{name, state:"passing"|"failing"|"pending"|"skipped", url?}` (`checks` come from the PR's rollup;
  `runs` — the branch's latest five workflow runs — only when there is no PR); `checksState` is
  `passing | failing | pending | none`.

## Scheduled prompts

[ADR 0027](../decisions/0027-scheduled-prompts.md), `security.md` #29. Bearer-gated, 30/min (run-now 6/min).

- `GET /schedules` → `{tz, offsetMin, now, schedules:[{id, projectId, projectName, title, prompt, mode, model, kind, time, days, runAt, enabled, nextRunAt, lastRunAt, lastStatus, lastSessionId}]}`. `tz` / `offsetMin` are the **server's** zone — daily times are its local clock.
- `POST /schedules {projectId, title, prompt, kind, …}` → `201` the schedule. `kind:"daily"` needs `time` (`HH:MM`) and optional `days` (distinct 0-6, Sunday = 0; `null` = every day); `kind:"once"` needs a future ISO `runAt`. `mode` is `ask` (default) | `plan` | `auto`; `model` optional. Limits: 50 schedules, title ≤ 120, prompt ≤ 8000. `400` bad/unknown field, `404` no such project, `403` project outside the allowed roots, `429` too many.
- `PATCH /schedules/:id` — any subset of the fields above plus `enabled`; retiming or re-enabling recomputes `nextRunAt`.
- `DELETE /schedules/:id` → `204` (idempotent). Sessions it already started are kept.
- `POST /schedules/:id/run` → `201 {sessionId}`: start a run now; does not move `nextRunAt`. `429` when the live-session cap is hit, `409` otherwise (e.g. the previous run still going).

A run is an ordinary session titled `⏰ <title>` primed with the prompt; `lastStatus` is `started`,
`missed`, `waiting: …` (retried each tick), `skipped: …` or `failed: …`.

## Branch a conversation

`POST /sessions/:id/fork {messageId, at?}` ([proposal 42](../proposals/42-branch-conversation.md),
[M14 spike](../spikes/M14-spike-fork.md)). `messageId` is a daemon `messages.id` of a *user* message
in this session (from the `history` frame); `at` is `"after"` (default — keep that turn and its
reply) or `"before"` (keep only what precedes it).

`201` → `{id, project_id, kind:"claude", title:"↳ …", status:"stale", created_at, model, copied}`.
The new session resumes independently (open it via `WS /session/:id` as usual); the original is
untouched. Errors: `400` bad body / a worktree or native-engine session · `403` project outside the
allowed roots · `404` unknown session, or the message isn't a user turn with a checkpoint (older
turns) · `409` no SDK conversation yet, a turn is running, or a later message can't be mapped ·
`500` (generic) when the SDK fails — nothing is created. Rate-limited 10/min; audited `session.fork`.
File checkpoints do not follow a fork, so rewind is unavailable for the copied turns.

## Git write (stage / commit / branch — no push)

[ADR 0024](../decisions/0024-git-write-surface.md), `security.md` #26. Two scopes with
identical bodies: `/projects/:id/git/<op>` (the project checkout) and
`/sessions/:id/git/<op>` (the session's checkout — its worktree if it has one,
ADR 0022; Claude sessions only). All bearer-gated, 30/min, one write at a time per
checkout. Failures are generic (`409 git refused …`) — git's own stderr is never echoed.
One exception: a repo whose git config defines a filter, merge or diff driver command
or an `includeIf.onbranch:` include is refused with `409 repo_config_unsafe: <key>` — the
key name only, never its value (ADR 0032 §4). Worktree creation reports the same text.
Stage with no `paths` (`add -u`) returns `409` in a repo with submodules; pass explicit paths.

| Op | Body | Notes |
|----|------|-------|
| `stage` | `{paths?: string[], allowSensitive?: bool}` | Relative or absolute paths **inside the checkout**, ≤500, passed after `--` as *literal* pathspecs (no globs). Refused with `400`: leading `-`, NUL, outside the checkout (incl. symlink escapes), anywhere under `.git`, a directory (name files), and secret-looking names (`.env*`, `*.pem`, `*.key`, `*.p12`, `*.pfx`, `id_rsa`/`id_ed25519`…, `.netrc`) unless `allowSensitive:true`. **No `paths`:** project scope = `git add -u` (tracked changes only, never untracked); session scope = the session's own edit set (secrets and out-of-checkout files skipped). → `{staged: [paths]}` |
| `commit` | `{message}` | 1–500 chars, no NUL, must not start with `-` (`400`); nothing staged ⇒ `409`. Message is the value of `-m`. Author = the paired device (`user.name` = device name, `user.email` = `<deviceId>@vibe.local`). `--no-verify`, no GPG. → `{sha, subject, filesChanged}` |
| `branch` | `{name}` | `^[A-Za-z0-9][A-Za-z0-9._/-]{0,63}$`, no `..` `@{` `//`, no trailing `/` or `.lock`, re-checked by `git check-ref-format`. Creates **and switches** (`checkout -b`); `409` if the name exists or tracked files have uncommitted changes (untracked files don't block). No delete, no force. → `{branch}` |

`GET /sessions/:id/git-status` is the read-only status of the session's own checkout
(the project route can't see a worktree). There is **no** push, pull, fetch, reset,
rebase, merge, remote or stash route (`404`). Audited `git.stage` / `git.commit`
(message cut to 80 chars) / `git.branch`.

## Settings (session rules + disk limits)

[ADR 0026](../decisions/0026-session-rules-and-settings.md), `security.md` #27. Bearer-gated.

`GET /settings` → `{settings: [{key, type, value, default, isDefault, min?, max?, maxLen?}]}` for the
five known keys (`rules.enabled`, `rules.text`, `disk.alert_percent`, `disk.min_free_gb`,
`disk.daemon_data_alert_gb`).

`PUT /settings {values: {key: value, …}}` (30/min) → the same view. `null` resets a key to its
default. All-or-nothing: an unknown key, wrong type or out-of-range value is `400
{error:"<key>: <why>"}` and nothing changes. Audited `settings.update` (key names; `rules.text` as
its length only).

`GET /system` also returns `footprint` (the daemon's own disk use) and `limits` (the thresholds in
force) — see [ADR 0026](../decisions/0026-session-rules-and-settings.md).

Effects: the rules text is appended to the system prompt of every session **started after** the
change; `disk.alert_percent` is read by `GET /system` and the monitor on every tick;
`disk.min_free_gb` makes `POST /sessions` and `POST /projects` answer `507
{error:"Only 3.0 GB free where this lives (minimum 5 GB) — …"}` (and audit `session.disk_guard`).

## Audit log + devices (admin surfaces)

`GET /events?limit=<n>&before=<iso>&kind=<prefix>` →
`[{id, kind, device_id, detail, ts}]`, newest first. `limit` is clamped to **200**
server-side; page backwards with `before=<ts of the last row>`; `kind=` matches by
prefix (`permission` covers `permission.allow|deny|auto_allow|timeout`).

- **Read-only.** No `POST`/`PATCH`/`DELETE` — a mutable audit log isn't one.
- **The read is not itself audited** (it would amplify without informing).
- Disclosure note: `detail` carries session ids, tool names and absolute paths.
  Bearer-gated behind the tailnet, same as `GET /projects` (security.md #14).

`GET /devices` returns `{id, name, paired_at, last_seen, current}`; `current`
marks the calling device so the client can warn that revoking it signs the app
out. `DELETE /devices/:id` is unchanged (security.md #4) — the app now calls it.

## External sessions (discovery)

`GET /sessions?project_id=` also picks up sessions started **outside** the
daemon — e.g. the `claude` CLI run directly over SSH in a project directory —
so a session can be started either way and continued from the other
(`vibe-daemon/src/discover.ts`).

Before listing, the daemon scans that project's Claude Code transcript dir,
`~/.claude/projects/<path with every "/" replaced by "-">/*.jsonl`, and
inserts a row for any `.jsonl` (session id) it doesn't already have —
`kind:'claude'`, `claude_session_id` = the filename, **`status:'stale'`** (not
`live` — see [Concurrency caps](#concurrency-caps): a project can easily have
more old transcripts than the live cap, so a discovered row only counts once
actually opened). Its first `WS /session/:id` attach backfills `messages` from
that transcript (`vibe-daemon/src/transcript-import.ts`) before resuming, so
the app's history matches the CLI's exactly, and flips the row to `'live'`
(`claude-ws.md`).

**Deleting a discovered row** (`DELETE /sessions/:id`) records its
`claude_session_id` in `dismissed_transcripts`, and discovery skips those ids —
otherwise the untouched `.jsonl` would re-list it on the next `GET /sessions`.
The transcript itself is never touched, so `claude --resume` still works on the
server. The same applies to any daemon-created claude row that got a
`claude_session_id`, since the SDK writes its transcript to the same dir.

**Bulk clear:** `POST /sessions/prune {project_id, older_than_days?}` deletes the
project's `stale` rows (all, or only those with `created_at` older than N days)
exactly like per-row `DELETE` — dismissed so discovery won't re-list, transcript
untouched. Live rows and any session a CLI is running right now are skipped.
Audited as `session.prune`. The app exposes it as "Clear stale" on the project's
session screen.

**Empty and titled on discovery:** a transcript with no user turn is not
registered (the CLI push hook, `hook.ts`, still registers one — its first turn
may not be flushed yet). A discovered row is titled from the CLI's own
`{"type":"ai-title"}` transcript entry when present, else by the first-prompt
heuristic on attach (ADR 0009); the mirror keeps it current as the CLI refines
it. A manual rename pins the title as before.

**Still running on the server:** a listed row whose CLI process is live right
now carries `external: {status: "busy"|"idle"}`. Opening it mirrors the CLI
rather than resuming (one writer per transcript) — see
[claude-ws.md](./claude-ws.md) and [ADR 0012](../decisions/0012-external-session-mirror.md).

## Status field

`sessions.status` (`PLAN.md §3`) reflects the backing process:

| status | meaning | set when |
|--------|---------|----------|
| `live` | backing tmux/SDK process running | on create; on successful WS attach |
| `dead` | shell exited / SDK ended | terminal `onExit`, or SDK session end |
| `stale` | row exists but `tmux has-session` misses (e.g. machine rebooted) | lazily, when an attach `4404`s — see reattach.md follow-up |

`GET /sessions` returns this so the dashboard greys out non-`live` sessions
instead of offering a dead attach.

## Create → attach sequence

```
app ── POST /sessions {kind:terminal} ──► daemon: tmux new-session -d vibe-<id>
    ◄── 201 {id: s_42, status: live} ────  + insert row
app ── WSS /pty/s_42  (Bearer) ─────────► has-session? → attach (reattach.md)
    ◄── raw tmux bytes ─────────────────
   (drop / IP roam → reconnect to the SAME s_42, attach-only)
app ── DELETE /sessions/s_42 ───────────► kill-session + drop row
    ◄── 204 ────────────────────────────
```

## Build dependencies (not yet in repo)

This contract presumes infrastructure that lands first — flagged so the doc
isn't mistaken for buildable-today:

- **M1 auth** — bearer-token middleware on every route (`PLAN.md §2C`). REST
  session endpoints must not ship before it; they create real shells.
- **SQLite layer** — `projects` / `sessions` tables via `better-sqlite3`
  (`PLAN.md §3`). `POST /sessions` needs a valid `project_id`.
- **tmux wiring** — the `-L vibe` lifecycle from ADR 0004.

Until then, `serve-pty.ts` stays the spike (create-on-connect); it is **not** the
M2 shape and should be replaced, not extended.

## Gotchas

- WS close = **detach**; only `DELETE /sessions/:id` kills. Never let the byte
  channel destroy a session (reattach.md).
- Validate `project_id` exists and its `path` is inside the allowed roots before
  spawning a shell there — this is a shell-over-network surface (`docs/security.md`).
- `kind=claude` rows carry a null `claude_session_id` until the first SDK `init`;
  resume is impossible before then — the dashboard should reflect "not started".

## Follow-ups

- Decide id scheme (uuid vs. short slug) — must be URL-safe and stable.
- Reconcile `status` on daemon boot: sweep `sessions`, mark rows `stale` whose
  `tmux has-session` misses, so a reboot doesn't leave phantom `live` rows.
- Audit-log create/delete to the `events` table (`PLAN.md §3`).
