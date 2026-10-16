# ADR 0030 — Project file writes and transfer

**Status:** Accepted (2026-10-16). Proposal [59](../proposals/59-project-files-transfer.md).
Extends the read-only browser (ADR 0010, proposal 46, `security.md` #31).

## Context

Every project-file route so far is read-only and session-scoped. Proposal 59 adds a Files
screen per project (no chat needed), text save for the editor (proposal 60), and binary
download/upload. This is the first general **write** surface over project files from the phone.

Trust model: a paired device can already run a shell and Claude with write access in these
projects, so writes add no new *capability*. What they must not add is a new *path*: out of the
project roots, into `.git` (hooks and config run code, ADR 0024), or into secret files.

## Decision

1. **One module, two scopes.** `project-files.ts` registers every route under both
   `/projects/:id/files…` and `/sessions/:id/files…` (session → its worktree, else the project
   path), with `pathInRoots` on the root, as in `git-write.ts`. Any session kind.
2. **Same rules as the browser, shared code.** `resolveInside`, `looksSecret`, `listDir` come from
   `browse.ts` (no copies). Lexical check before the filesystem, realpath re-check, `.git`
   invisible by any spelling or symlink, identical 403 in and out of root, secrets listed but
   refused for read, download and write.
3. **Text read/write with optimistic concurrency.** `GET …/files/text` returns
   `{path, content, sha, mtime, size}`; `sha` = sha256 hex of the file bytes. Files over
   `VIBE_MAX_EDIT_BYTES` (2 MiB) are **413, not truncated**: a truncated buffer must never be
   saveable. NUL in the first 8 KiB → 415. `PUT …/files/text {path, content, baseSha | create:true}`
   → 409 `{sha}` when the current bytes don't hash to `baseSha` (Claude or another device changed
   the file); `create:true` → 409 if it exists.
4. **Atomic writes, no surprises.** Write to `.<name>.vibe-<random>.tmp` in the target's real
   directory (`wx`, mode copied from the existing file, else 0644), fsync, rename over the
   target, fsync the directory. Temp removed on any failure. An in-root symlinked file is written
   at its real path (the link survives). Targets must be regular files; the parent folder must
   already exist (no implicit mkdir → 404). A new file's name must be a single valid segment, not
   `.git`, not secret-looking. A per-project mutex serialises writes; the sha check and rename
   happen inside it. Residual: an agent write landing between check and rename is lost — the
   window is milliseconds, and the same as two editors on one disk.
5. **Transfer.** `GET …/files/raw` streams any non-secret regular file (binary ok) as
   `application/octet-stream`, `Content-Disposition: attachment` (RFC 5987 encoded name),
   `X-Content-Type-Options: nosniff`; over `VIBE_MAX_DOWNLOAD_BYTES` (200 MiB) → 413.
   `PUT …/files/raw?path=&overwrite=0|1` streams the body into the temp file, counting bytes;
   over `VIBE_MAX_UPLOAD_BYTES` (100 MiB) → abort, delete temp, audited 413. Without
   `overwrite=1` an existing target is 409. `diskGuard` (ADR 0025) runs first → 507.
   These routes live in an **encapsulated plugin** with their own body handling, so the root
   5 MiB `application/octet-stream` parser in `attachments.ts` keeps working unchanged.
6. **Limits and audit.** All routes sit behind the global auth hook and are rate-limited.
   Audited: `file.read` (text), `file.write`, `file.download`, `file.upload`, and rejected uploads
   (`file.upload_reject`), detail `<scope>:<id>:<bytes>:<path>`. Error bodies never echo
   absolute paths.
7. **Not in scope:** delete, rename, mkdir, folder/zip transfer, resumable transfers. Each needs
   its own decision. The existing `/sessions/:id/browse` routes stay for older app builds.

## Consequences

- The phone can now change project files without going through Claude. A stolen paired device
  could already do that via the terminal; device revocation (`security.md` #4) is the control.
- An upload can plant a file that a later Claude or CI run executes (for example a script). This
  equals what the terminal already allows and is visible in git status and the audit log.
- 409-on-stale-sha means the editor must offer reload / overwrite / diff; the daemon never merges.
- Covered by `project-files.test.ts`; listed as `security.md` #33.
