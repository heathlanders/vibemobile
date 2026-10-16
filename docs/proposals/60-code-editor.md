# 60 — Built-in code editor

**Status:** accepted 2026-10-16 · depends on [59](59-project-files-transfer.md) (files API)

A VS Code–like viewer/editor in the app (phone + Windows) for any file in any project, with the
owner's VS Code habits baked in: syntax highlighting + themes, Prettier, ESLint shown Error-Lens
style, Markdown preview, find/replace, git change gutter, GitLens-lite blame, rainbow brackets,
indent guides.

Today code is plain `SelectableText` (`FileViewerScreen` in
`chat/presentation/file_browser_screen.dart`, `FileDiffScreen._FileView`); no editor, highlight or
markdown package.

**Package:** `re_editor` + `re_highlight` — see [spike](../spikes/editor-package.md) (virtualized
rendering, highlight in an isolate, `CodeFindController`, `spanBuilder`, `indicatorBuilder`).
No multi-cursor.

## Phase 1 — core editor
- Feature `app/lib/features/editor/{data,domain,presentation}`; Riverpod doc state (content,
  baseSha, dirty, language, readOnly).
- **First:** perf check — open a 2 MiB / 50k-line file on the phone and on Windows (typing lag,
  scroll). If it fails, lower `VIBE_MAX_EDIT_BYTES`.
- `CodeEditorScreen`: extension → re_highlight `Mode`; theme follows app (Dark+ ≈ `vs2015`,
  Light+ ≈ `vs`); JetBrainsMono; line numbers; folding; current-line highlight.
- Find/replace bar (`findBuilder` over `CodeFindController`, regex/case toggles).
- Save (Ctrl+S + button) via `PUT files/text`; dirty dot; leave-confirm; **409 dialog**
  (reload / overwrite / show diff). Read-only for truncated or secret-adjacent files.
- Shortcuts (custom `CodeShortcutsActivatorsBuilder`): Ctrl+F, Ctrl+H, Ctrl+S, Ctrl+Z/Y,
  Ctrl+Shift+Z, Tab/Shift+Tab, Alt+↑/↓. Android: toolbar with Select all / Undo / Redo / Find.
- **Preview toggle:** Markdown via the existing `MarkdownText` widget
  (`chat/presentation/markdown_text.dart`); JSON pretty-printed.
- **Entry points:** project Files screen (59), chat "Browse files…" (`chat_screen.dart:1112`),
  chat file links `openChatFile()` (`file_browser_screen.dart:125`) open at the line. Replace
  `FileViewerScreen` and `FileDiffScreen._FileView` with the shared code view (read-only there).
- **Desktop:** files open as a tab kind in `workspace/presentation/workspace_screen.dart` (beside
  chat tabs, Ctrl+W closes, dirty prompt). Phone: pushed route.

## Phase 2 — format + lint (Prettier, ESLint → Error Lens)
- Daemon `POST …/files/format {path, content}` → `{content}`; `POST …/files/lint {path, content}`
  → `{diagnostics:[{line, col, endLine?, endCol?, severity, message, rule?, source}]}`.
- Execution rules (security): fixed allowlist by extension, `execFile` (no shell), cwd = project
  root, content on **stdin**, no client-supplied args, 15 s timeout, output cap, rate limit, audit
  `file.format` / `file.lint`. Missing tool → 501 with a clear message.
  - Prettier: project `node_modules/.bin/prettier` else global — `--stdin-filepath <path>`.
  - ESLint: project-local only — `--stdin --stdin-filename <path> --format json`.
  - Dart: `dart format` via stdin; `dart analyze` only on the saved file (no stdin mode).
  - Running a project's own prettier/eslint executes its config (JS). Same trust as a Claude
    session in that project — record in ADR 0030.
- App: Format (Shift+Alt+F + menu), setting "Format on save"; lint on open, on save, and debounced
  while typing. **Error Lens:** severity dot in the gutter (`indicatorBuilder`) + end-of-line
  message (trailing span in `spanBuilder`; fall back to an overlay painter if caret hit-testing
  breaks). Problems list sheet (tap → jump to line).

## Phase 3 — git + visual extras
- Daemon `GET …/files/head?path=` → HEAD blob (`git show HEAD:<path>` via execFile, reuse
  `git-write.ts` helpers; 404 if untracked). App line-diffs buffer vs HEAD → gutter bars
  (added / modified / deleted), updates as you type.
- **GitLens-lite:** `GET …/files/blame?path=` (`git blame --porcelain`) → faint end-of-line hint on
  the current line: author · relative date · summary.
- **Rainbow brackets:** `spanBuilder` recolours `()[]{}` by depth; per-line depth cache rebuilt
  from the edit line onward on change.
- **Indent guides:** overlay `CustomPainter` driven by the indicator paragraph offsets + horizontal
  scroll offset.

## Out of scope
Multi-cursor, LSP / autocomplete / go-to-definition, multi-file search, extensions marketplace,
terminal-in-editor.

## Docs to update
`docs/protocols/session-rest.md` (format/lint/head/blame), `docs/security.md` (exec rules),
`.claude/docs-map.md` (editor row), ADR 0030 (formatter/linter execution).

## Verification
- Daemon tests: format/lint allowlist (unknown extension → 415/501), no shell metacharacter
  effect from paths, timeout kill, output cap, head/blame for tracked/untracked/outside files.
- App widget tests: open → edit → save; 409 dialog; find/replace; preview toggle; diagnostics
  render in gutter; desktop tab dirty prompt.
- On device (phone + Windows): edit + save while Claude edits the same file → 409 path; format a
  TS file with Prettier; ESLint errors inline; gutter marks after editing a tracked file;
  2 MiB file usable.
