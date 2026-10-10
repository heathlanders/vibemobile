# Proposal 06 — Message copy / export

## Why
Get text out of the chat fast: copy a single reply (code, command, paste
elsewhere) or grab the whole transcript. Bubbles use `SelectableText` today —
manual drag-select works but is fiddly on mobile; no one-tap copy, no transcript
export.

## Sketch
Two affordances, client-only:
- **Per-message copy** — long-press a bubble → `Clipboard.setData(message.text)`
  + "Copied" snackbar. Tool chips copy `toolName` + input JSON. Keep
  `SelectableText` for partial selection.
- **Copy / share transcript** — AppBar overflow menu → copy or share the full
  transcript. Format `_controller.messages` as `role: text` lines, skip
  `result`/empty.

## Impact
- **Wire:** none (reads in-memory `messages`).
- **Schema:** none.
- **Client:** `_Bubble` long-press handler (chat_screen.dart); AppBar menu;
  optional `share_plus` dep for the share-sheet — ship copy-only if absent.

## Open
- Transcript format: plain `role: text` vs Markdown (fenced tool blocks). Start
  plain.
- Include tool calls / permission outcomes in transcript export, or messages
  only? Default: include tool calls, skip permission cards.

## Status (2026-10-06)
Shipped. Long-press / right-click copy, **Copy transcript**, and **Share
transcript…** (chat ⋮ menu). Share uses `share_plus` with the same plain
`You:/Claude:/Tool:` text as Copy, and the session title as the subject. It's
text only, so no FileProvider. `share_plus` is a new client dependency (Android,
Windows, Linux plugins).

## Bug (2026-10-10, phone Notes)
"Copied text should keep its line breaks." Long-press copy and Copy transcript use the raw
`message.text`, so they keep `\n`. The suspected path is **desktop drag-select**: the chat list sits in
one `SelectionArea`, and a markdown bubble is a column of separate block widgets (paragraphs, list
items, code), so the selected text can lose the newlines between blocks. Fix plan: reproduce it in a
widget test first, then make block boundaries copy as `\n` in `markdown_text.dart`.
