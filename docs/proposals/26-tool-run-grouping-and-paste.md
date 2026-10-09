# 26 — Collapsed tool runs, clipboard image paste, send while busy

Status: **shipped (code)**. Client only, no daemon or wire change. Not yet run
against a real session or a Windows build.

## Problem

1. A busy turn emits dozens of `tool_use` rows. Each rendered as its own chip,
   so the actual conversation scrolled out of view. Applies to phone and desktop
   (same `ChatScreen`).
2. Desktop could attach images only via the file dialog or drag-drop. Pasting a
   screenshot (Win+Shift+S, then Ctrl+V) did nothing.

## What shipped

**Tool runs.** `chat/domain/tool_groups.dart` folds every consecutive run of
`ChatRole.tool` messages into a `ToolRun` at render time. The message list and
transcript cache are unchanged. `ChatScreen` shows a run as one muted row:
`N tool calls · Read ×3 · Bash`, an error icon if any call failed, and a spinner
while the live tail is still running. Tap to expand inline; each call then shows
the existing chip with its expandable result (proposal 07). Closed by default.
Expansion is held in `_openRuns`, keyed by the run's first call.

A run ends at any non-tool row (assistant text, user turn), so text between tool
bursts stays visible.

**Paste.** Desktop only. The composer's `FocusNode` intercepts Ctrl/Cmd+V and
calls `_paste()`. It reads `Pasteboard.image` (new dep `pasteboard`) and, if
there is one, uploads it through the same path as the picker and drag-drop. If
there is none, it inserts the clipboard text at the caret. The clipboard read is
async, so the key is always consumed and text paste is done by hand.

**Send while busy.** The composer used to swap Send for Stop during a turn, and
desktop Enter was ignored. Now Stop sits beside Send, and Enter sends. No daemon
change: `pushUser` has no busy guard and feeds the SDK's streaming input.

Spike (`vibe-daemon/src/spike-midturn.ts`, re-run `pnpm tsx src/spike-midturn.ts`):
a message pushed 5s into a `sleep 12` turn was accepted and delivered at the next
tool boundary (user-echo at +15.8s), so the reply covered both. **One `result`
came back for both messages**, so the client keeps `busy` as a plain flag cleared
by `result`. An in-flight counter would have stuck on.

## Known limits

- A message sent in the last instant of a turn (after the final tool boundary)
  may start a second turn. The first `result` then clears `busy` while that turn
  runs; the Stop button briefly disappears. Not seen in the spike.
- The user bubble is appended at the end of the list at send time. A reply still
  streaming above it keeps growing there.

- Right-click → Paste in the text field still pastes text only.
- Pasted images aren't downscaled (the phone picker caps at 1568px). A large 4K
  screenshot can hit the daemon's size limit (413); the existing upload-failed
  snackbar shows it.
- Copying files in Explorer then pasting is not handled; use drag-drop.
- `pasteboard` also registers on Android/iOS but is never called there
  (`_onComposerKey` returns early on mobile).

## Open

- A per-user "always expanded" toggle, or a side pane for tool activity, if the
  inline collapse isn't enough.
