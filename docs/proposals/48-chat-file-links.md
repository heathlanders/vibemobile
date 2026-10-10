# 48 — File paths in chat open in the app

**Status:** building: code + tests done 2026-10-10, on-device check pending

Claude often points at a file to review ("see `docs/proposals/46-file-browser.md`",
"`src/browse.ts:42`"). Today only `http(s)` links are tappable (proposal 34, `link_spans.dart`; and
markdown links in `markdown.dart`), so the user has to dig through Browse files… by hand. Make file
references tappable, and open them **inside the app** with the existing viewer (proposal 46).

- **Detect** (client): add a `FileLink(path, line?)` span alongside the URL span.
  - Inline code or bare text that looks like a path: has a `/` or a known file extension, with an
    optional `:line` (`docs/foo.md`, `app/lib/x.dart:120`, `README.md`).
  - Absolute paths. These are handed to the daemon as they are; it reads an absolute path as
    relative to the root and refuses anything outside it.
  - Markdown links whose target isn't `http(s)` (`[plan](PLAN.md)`).
  - The URL rules stay exactly as they are. False positives to reject: version numbers (`1.0.17`),
    `e.g.`/`i.e.`, domains without a scheme, bare words with no `/` and no known extension.
- **Open:** use `GET /sessions/:id/browse/file` (proposal 46), which already handles confinement,
  hidden secrets and `.git`, text-only reads and auditing. **No new daemon surface.** A `403`/`404`/`415`
  becomes a snackbar ("Not in this project" / "File not found" / "Binary file"). With `:line`, the
  viewer scrolls to that line and highlights it.
- **Desktop:** if the workspace has a pane for files, open the file there; otherwise push
  `FileViewerScreen` as on mobile.

Security: this is a new *trigger* for an existing, reviewed read path; it doesn't widen what can be
read. Text from Claude is still treated as data. A link only builds a `browse/file` request for the
current session, and nothing is executed or opened outside the app.

Out of scope: opening files outside the session's checkout, editing, linking to symbols, images.

Tests: unit tests for the path detector (positives, false positives, `:line` parsing, and that URLs
are unaffected); a widget test that tapping a file link opens the viewer with the right path and line.

## What shipped

- `domain/file_refs.dart`: pure detector (`detectFileRef` for inline code, `splitFileRefs` for stricter
  bare text, `fileRefFromLinkTarget` for `[t](target)`). Schemes (`javascript:`, `file:`, `mailto:`),
  `www.`, `..` and TLD-only names are rejected.
- `parseInline(..., fileRefs: true)`, `MarkdownText` and `LinkifiedText` take `onOpenFile(path, line)`;
  with it null (default) nothing is linkified. http(s) links are unchanged.
- `openChatFile` reads via the existing `browse/file` (current session only) and pushes
  `FileViewerScreen`; 403/404/415 become a snackbar ("Not in this project" / "File not found" /
  "Binary file"). The viewer takes an optional `line` and scrolls to and highlights it.
- Desktop: the workspace has no file pane, so the viewer is pushed as on mobile.
- Tests: `app/test/file_links_test.dart`. No daemon changes.
