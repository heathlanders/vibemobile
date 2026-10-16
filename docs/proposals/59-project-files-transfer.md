# 59 — Project files API + file transfer

**Status:** accepted 2026-10-16

From the Notes inbox: "transfer files to and from server to client pc". Also the base the code
editor (proposal 60) builds on: today every project-file route is read-only and session-scoped
(`browse.ts`, proposal 46: "No writes of any kind").

## Design

### Daemon — `vibe-daemon/src/project-files.ts` (new)
- Registered under **both** `/projects/:id/...` and `/sessions/:id/...`, using the
  `projectCtx`/`sessionCtx` loop from `git-write.ts:194-238` (session → its worktree, else the
  project path; `pathInRoots` check). So files are reachable without opening a chat.
- **Reuse, don't copy**: export `resolveInside`, `looksSecret`, `listDir` from `browse.ts`.
  Same rules everywhere: lexical check before touching the fs, symlinks followed and re-checked,
  `.git` invisible, secrets listed but refused, same 403 in/out of root (no existence oracle).
- Routes (all behind the global auth hook, each rate-limited, audited):
  - `GET  …/files?path=` → listing (same shape as browse).
  - `GET  …/files/text?path=` → `{path, content, sha, mtime, size, truncated}`. Cap
    `VIBE_MAX_EDIT_BYTES` (default 2 MiB); NUL sniff → 415.
  - `PUT  …/files/text` `{path, content, baseSha, create?}` → write to a temp file in the same dir,
    fsync, rename. `409 {sha}` when the file's sha ≠ `baseSha` (Claude edited it meanwhile).
    `create:true` → must not exist (`wx`). Refuse `.git`, secrets, symlink escapes, non-regular
    targets. Audit `file.write` (`ctx:path:size`).
  - `GET  …/files/raw?path=` → stream any file (binary ok), `Content-Disposition: attachment`.
    Cap `VIBE_MAX_DOWNLOAD_BYTES` (default 200 MiB) → 413. Secrets refused. Audit `file.download`.
  - `PUT  …/files/raw?path=&overwrite=0|1`, `application/octet-stream` → stream to temp in the
    target dir, fsync, rename; `wx` unless `overwrite=1` (409 otherwise). Cap
    `VIBE_MAX_UPLOAD_BYTES` (default 100 MiB) → audited 413. Same refusals as text writes.
    Audit `file.upload`.
- **Gotcha:** `attachments.ts:82` registers an `application/octet-stream` parser on the root app
  with a 5 MiB `bodyLimit`. The raw routes go in an **encapsulated plugin** with their own parser /
  route-level `bodyLimit` (or stream the raw request) so neither breaks the other.
- New dirs: uploading into a missing folder → 404 (no implicit mkdir), keeps the surface small.

### App
- `app/lib/features/files/{data,domain,presentation}`: `ProjectFilesApi` (Dio), Riverpod providers.
- **Project-level Files screen** (from the project screen / desktop sidebar), reusing the browser
  list UI; chat "Browse files…" switches to the new API.
- **Download:** per-file action. Android: save to Downloads (`path_provider`), then
  `share_plus` / `open_filex`. Windows: save dialog (`file_picker`). Progress from Dio
  `onReceiveProgress`.
- **Upload here:** folder action, `file_picker` (new dep); desktop also drag-and-drop via
  `desktop_drop`. Progress from `onSendProgress`; 409 → "Overwrite?" prompt.

## Security
Adds the first general **write** surface over project files. Trust model: a paired device can
already run a shell and Claude with write access in these projects, so writes add no new
capability, but they must stay inside project roots and never touch `.git` or secrets.
Record as ADR 0030 (project-file writes) + new `docs/security.md` items; `reviewer` on the diff.

## Out of scope
Delete / rename / mkdir, folder upload/download (zip), resumable transfers.

## Docs to update
`docs/protocols/session-rest.md` (new section), `docs/security.md`, `.claude/docs-map.md` (row for
project-file writes/transfer), ADR 0030.

## Verification
- Daemon tests (`project-files.test.ts`, modeled on `browse.test.ts` + `attachments.test.ts:72`):
  traversal, symlink escape, `.git` in any spelling, secret names, 403 parity in/out of root,
  409 on stale sha, `wx` create, overwrite flag, upload/download over cap → 413, binary round trip,
  project vs session root.
- App widget tests with a fake API (pattern: `app/test/browse_test.dart`).
- On device: upload a >5 MiB binary from phone and from Windows; download it back; compare sha256.
