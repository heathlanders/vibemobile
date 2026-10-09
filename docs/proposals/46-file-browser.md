# 46 — Read-only file browser

**Status:** implemented (daemon + app + tests 2026-10-07; on-device check pending)

Browse a chat's project and read its text files from the phone. Until now you could only see files
Claude had *edited* (`/sessions/:id/file`, proposal 20) or filenames for `@` completion (ADR 0010).

- **REST** ([session-rest.md](../protocols/session-rest.md#file-browser)):
  `GET /sessions/:id/browse?path=<folder>` → `{path, entries:[{name, type:"dir"|"file"|"link", size?,
  readable}], truncated}` and `GET /sessions/:id/browse/file?path=<file>` → `{path, size, truncated,
  content}`. Paths are relative to the session's checkout (its worktree if it has one).
- **Daemon** (`browse.ts`) — a new read surface over project files, so deliberately narrow:
  - **Confined.** The path is checked lexically (`..` can't leave the root) **before** the filesystem
    is touched, then symlinks are followed and the result must still be inside the root. A path
    that doesn't exist is judged by its nearest existing ancestor. Result: a path outside the project
    gets the same `403` whether or not it exists — **no existence oracle** (an earlier draft
    returned `404` vs `403`, which would have let a paired device map files outside the project; a
    test now pins the two answers to be identical). An absolute path is read as relative.
  - **Secrets are listed but never readable.** `.env*`, `*.pem/key/p12/pfx`, `id_*`, `.netrc`
    (the git-write deny-list) plus `.npmrc`, `.pypirc`, `.git-credentials`, `*.keystore/jks/gpg`,
    `credentials(.json)`, `secrets.*`, service-account / client-secret JSON, `*.tfstate`, `*.tfvars`.
    A symlink to a secret is judged by its real name too.
  - **`.git` is invisible and unreadable** by any spelling, including through a symlink (remote URLs
    with tokens, hooks, config the agent can edit).
  - **Text only**: 256 KiB cap (flagged `truncated`), NUL-sniffed first 8 KiB → `415` for binaries
    (e.g. `vibe.db`); folders cap at 500 entries (flagged). Sockets/devices aren't listed.
  - No writes of any kind. 90/min. Every successful file read is audited `file.browse`
    (`session:path:size`); refused reads are not logged as reads.
- **App:** "Browse files…" in the chat menu → `FileBrowserScreen` (folders first, sizes, lock icon for
  secrets, broken-link icon for links that leave the project, "Empty folder", and Back goes **up a
  folder** before it leaves the screen) → `FileViewerScreen` (monospace, selectable, scrolls both
  ways, copy button, a plain message for binaries).

Checked against the real repo: `.git` not listed, `CLAUDE.md` read, `vibe.db` → 415, `.git/config` /
`../../../etc/passwd` / `../.ssh` / `../.config/vibe-daemon.env` → refused with no content.

Out of scope: editing, search, syntax highlighting, images, downloading, browsing outside the
checkout, a project-level (session-less) browser.

Tests: `vibe-daemon/src/browse.test.ts`, `app/test/browse_test.dart`.
