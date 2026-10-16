# Spike — code-editor package for the in-app editor (proposal 60)

**Question:** which Flutter package can carry a VS Code–like editor on Android and Windows:
large files, find/replace, folding, gutter markers (git diff, lint), rainbow brackets,
indent guides, Error Lens–style inline messages?

**Method:** read the source of both candidates (`dart pub unpack`), pub.dev metadata and
GitHub issues. 2026-10-16. Desk research only — the on-device perf check is still open (below).

## Results

| | **re_editor 0.10.0** (+ re_highlight 0.0.3) | **flutter_code_editor 0.3.5** |
|---|---|---|
| Maintenance | published 2026-07, repo active; MIT | published 2025-09, no pushes since ("Dead?" issue); Apache-2.0 |
| Large files | renders visible lines only; highlighting in an isolate | one `TextField` in a scroll view — lays out the whole file |
| Find/replace | `CodeFindController` (regex, replace, replace all); UI is ours via `findBuilder` | search UI, no replace |
| Folding / line numbers / current line | yes / yes / yes | yes / yes / no |
| Span hook after highlight | `CodeLineSpanBuilder spanBuilder` (per line) | `buildTextSpan` (whole doc) |
| Gutter | `indicatorBuilder` + `CodeIndicatorValueNotifier` (visible paragraphs with offsets) | fixed error gutter |
| Languages / themes | re_highlight, 197 langs; vs2015, vs, github(-dark), atom-one-* | `highlight` 0.7 (2021) |
| Undo/redo, read-only, jump to line | yes | yes; jump is awkward |
| Multi-cursor | no | no |

Known re_editor issues: #126 (50k-line SQL edit hang), #101 (very large scroll),
#54 (memory when setting `.text` repeatedly — use `replaceSelection`), #28/#117 (Android IME
gets the current line only: select-all and doc-wide keyboard navigation are limited).

## Decision

**re_editor + re_highlight.** flutter_code_editor's whole-document `TextField` rules it out
at the 2 MiB editor cap.

What we build on top of it:
- Find/replace bar → `findBuilder` over `CodeFindController` (`example/lib/find.dart`).
- Rainbow brackets → `spanBuilder` recolouring bracket chars; per-line depth cache.
- Git + lint gutter → custom widget in `indicatorBuilder` beside line numbers / fold chevrons.
- Indent guides, Error Lens text → overlay painter from the indicator paragraph offsets
  (no built-in API); try a trailing span in `spanBuilder` first and check caret hit-testing.
- Ctrl+Y, Ctrl+H → custom `CodeShortcutsActivatorsBuilder`.
- Extension → re_highlight `Mode` table; Dark+/Light+ → `vs2015`/`vs`.
- Toolbar "Select all" on Android (works around #28).
- Multi-cursor: out of scope.

## Open

- On-device check: 2 MiB / 50k-line file on the phone and on Windows — typing lag, scroll jank,
  end-of-line span vs caret. Do this first in Phase 1; if it fails, lower the editor cap.
