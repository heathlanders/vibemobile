# 35 — Markdown in assistant messages

**Status:** implemented (code + tests 2026-10-07; on-device visual check pending)

Assistant replies render as markdown instead of raw text. Found by the gap analysis
against mainstream coding harnesses: every one of them renders code blocks.

- **Parser** (`app/lib/features/chat/domain/markdown.dart`, pure Dart, no package):
  fenced code (``` / ~~~, any length), headings, bullet + numbered lists (nested by
  indent, numbers preserved), block quotes, rules, GFM tables; inline `` `code` ``,
  `**bold**`, `*italic*`, `***both***`, `[text](url)`, `\` escapes.
  A new dependency was rejected: the subset is ~300 lines, the rest of the app's text
  handling is already ours, and ADR 0001 treats new dependencies as a stack decision.
- **Widget** (`chat/presentation/markdown_text.dart`): `MarkdownText`; code blocks scroll
  horizontally, monospace, with a copy button once closed; tables scroll horizontally.
  Wired for **assistant** bubbles only (`_align(..., markdown: true)` in `chat_screen.dart`);
  the user's own text and errors stay plain so what you typed is shown as typed.
- **Streaming:** an unterminated ``` fence renders as an *open* code block (no copy
  button) instead of flashing as prose; any other unclosed marker stays literal. The
  streaming cursor rides on the last text block, or sits below a code block / table.
- **Safety:** raw HTML is shown as text, never interpreted. Links are `http(s)` only
  (`[x](javascript:…)`, `file:` stay literal), open in the external browser, and a URL
  inside a code span is not linkified. Parsing never throws (fuzz-style test).
- **Copy / share / search** keep using the raw message text (the markdown source).

Out of scope: images, reference links, footnotes, setext headings, syntax
highlighting, task-list checkboxes, rendering markdown in tool output.

Tests: `app/test/markdown_test.dart` (parser table + widget).
