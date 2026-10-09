# Proposal 20 — Session file viewer (changed files + diffs)

## Why
Chat shows tool chips for `Edit`/`Write` but not *what* changed. Give a git-style
view per session: list of files touched → tap → unified diff, toggle to the
current full file. Works for live **and** past sessions.

Distinct from [proposal 02](02-diff-viewer.md) (pre-execution approval diff).
This is post-hoc history. The server-side diff builder built here is the natural
source for 02's future `diffPreview`.

## Sketch
Every tool call is already persisted in `messages.tool_json`
(`{id, name, input, result, isError}` — claude.ts). For `Edit`/`Write`, `input`
holds `file_path` + `old_string`/`new_string` (or `content`). The daemon
reconstructs per-file diffs from SQLite — nothing new on the wire, no WS change.

New REST (all bearer-gated, `file-edits.ts`):

| Route | Returns |
|-------|---------|
| `GET /sessions/:id/file-edits` | `[{path, relPath, edits, adds, dels, written, lastTs}]` — changed-files list |
| `GET /sessions/:id/file-edits/diff?path=` | `{path, relPath, edits:[{ts, tool, replaceAll, diff, adds, dels, truncated}]}` — per-edit unified diffs, ts order |
| `GET /sessions/:id/file?path=` | `{path, relPath, content, size, truncated}` — current file content (full-file toggle) |

Diff generation: `diff` (jsdiff — MIT, zero transitive deps, Myers diff used by
jest/mocha). Hand-rolled diff rejected: fiddly LCS edge cases vs vetted lib;
"render must equal execution" ethos (02). `structuredPatch(old, new, {context:3})`,
emit prefixed hunk lines.

**No chaining.** Sequential `Edit`s are disjoint snippets of an unknown full
file — can't honestly merge into one patch. Each edit renders as its own
section. `Write` → all-`+` lines (prior content unknown → `written` flag).
`MultiEdit` flattened defensively; `NotebookEdit` ignored.

Client: app-bar button in ChatScreen → changed-files bottom sheet → FileDiffScreen
(diff ⇄ full-file toggle). Server sends prefixed diff text; client only colors
lines by first char — no client diff lib.

## Impact
- **Wire:** none (REST only). → rows in [session-rest.md](../protocols/session-rest.md).
- **Server:** `file-edits.ts` (routes + pure helpers), `diff` dep.
- **Client:** `features/chat/` — domain `file_edits.dart`, data `file_edits_api.dart`,
  presentation `changed_files_sheet.dart` + `file_diff_screen.dart`, one app-bar icon.

## Security gate impact
New **file-read surface over the wire** (security.md row). Invariants:

- **Edit-set capability, not a file browser.** `/sessions/:id/file` serves only
  paths that appear in that session's own edit set — a path never in the
  session's `tool_json` is 404 before any fs access.
- **Root scope re-check.** `realpath` then `pathInRoots()` — an approved
  out-of-root edit is still not readable back. Regular files only.
- **Size cap + binary sniff.** `VIBE_MAX_FILEVIEW_BYTES` (default 512 KiB);
  NUL in first 8 KB ⇒ 415.
- **No silent truncation** (02 invariant). Every cut appends a visible
  `… +N lines truncated` marker and sets `truncated: true`.
- **Audited.** Every content read logs `file.read` with device id.
- Diff/list routes are DB-only — zero filesystem access. No new write surface,
  no shell-out.

## Known limits
- Bash-made edits (sed, `>` redirects) invisible — inherent to the tool_json
  source. Sheet footer states it.
- `Write` overwrite shows as all-additions; `written` badge is the honest signal.
- `replace_all` shows the old→new pair once, labeled "(replace all)".
