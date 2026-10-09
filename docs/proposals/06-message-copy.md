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
