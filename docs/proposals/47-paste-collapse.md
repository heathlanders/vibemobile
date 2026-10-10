# 47 — Collapse large pastes in the composer

**Status:** building: code + tests done 2026-10-10, on-device check pending

**What shipped:** `domain/paste_tokens.dart` (threshold, tokens, expand, formatter),
`presentation/paste_composer.dart` (chip controller, view sheet, folded-bubble widget), wired in
`chat_screen.dart`. Deviations from the text above: (1) the chip is a styled `TextSpan`, and a tap is
detected from the field's `onTap` (caret inside the token), because an editable cannot host tap
recognizers; (2) the sheet is view-only (Expand inline / Remove / Close), no editing; (3) draft text
is never persisted, so no sync issue; "Improve prompt" sends the expanded text. Still to do: check on
a phone that tapping the chip reliably lands the caret inside it.

A large paste currently goes into the composer as raw text: dozens of lines that push the caret off
screen and fill the chat bubble once sent. Claude Code's terminal UI collapses a large paste into a
`[Pasted text #1 +42 lines]` placeholder. Do the same here, and let the user expand it.

- **Detect** (client only): a `TextInputFormatter` on the composer catches any single insertion over
  **10 lines or 1,000 characters**. A formatter sees both desktop Ctrl/Cmd+V (`_paste()`, proposal 26)
  and the native paste menu on mobile, so there is one code path. The desktop `_paste()` text branch
  inserts through the same logic, so the text is never handled twice.
- **Store:** the text goes into a per-composer `pastes` map (`#N → text`). In its place the field gets a
  token `[Pasted text #N +L lines]`.
- **Show:** the token is drawn as a chip by a custom `TextEditingController.buildTextSpan`. Tapping it
  opens a sheet where the paste can be viewed, edited, expanded inline (the token is swapped back for
  the raw text), or removed (token and map entry go together).
- **Send:** every token is replaced by its full text before the message is sent, so the daemon and
  wire protocol are **unchanged**. The map is cleared after sending. A token the user has edited by
  hand, so it no longer matches, is sent as plain text.
- **Transcript:** a user bubble longer than the same limit is shown collapsed (first lines plus "Show N
  more lines"). Copying still copies the whole text.

Out of scope: collapsing Claude's replies or tool output (proposal 26 already folds tool runs),
attaching pastes as files, keeping paste history after a message is sent.

Tests: a unit test for the threshold and token/expand round trip; a widget test that tapping the chip
expands it and that send expands every token.
