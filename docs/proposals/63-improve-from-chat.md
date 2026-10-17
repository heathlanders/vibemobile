# 63 — Improve: type, or pick a chat message

**Status:** building (2026-10-17) · extends [ADR 0018](../decisions/0018-prompt-library-v2.md) and proposal [61](61-rule-packs-and-go-deeper.md)

## Problem

From the user: the chat **Improve** button only works on text already typed in the composer
("Type a draft first" otherwise), and on the phone the keyboard didn't come back afterwards.
They also want to improve something already in the chat: a message they sent, or a reply from
Claude, rather than retyping it.

## Design (client only, no daemon change)

- Chat's Improve (composer button and "Improve draft prompt" menu item) opens a **bottom sheet**:
  - A multi-line text box, prefilled with the composer draft (paste chips expanded). It is
    editable, and it autofocuses when empty. The sheet rises with the keyboard
    (`isScrollControlled` + `viewInsets` padding).
  - **"Or start from a message"**: the chat's recent user and assistant messages (newest first,
    up to 30, two-line previews labelled You / Claude, superseded turns skipped). Tapping one
    loads its text into the box for editing.
  - Two buttons, **Improve** and **Go deeper**. These replace the mode dialog for this entry
    point.
- Then the existing result dialog (Original / Improved). **Use improved** puts the text in the
  composer, replacing the draft.
- **Keyboard fix:** after the flow, the composer is unfocused and refocused on the next frame, so
  Android reopens the keyboard. A plain `requestFocus()` on a node that kept focus while dialogs
  were on top doesn't reopen the IME.
- The prompt library's Improve (prompt editor body) is unchanged: it has its own text field.

## Verification

- Widget tests: the sheet lists user and assistant messages and skips tools, thinking and
  superseded turns; tapping a message fills the box; Improve calls the API with the box text and
  mode; an empty box disables the buttons.
- On device: on the phone, Improve from an empty composer, type in the sheet, use the result,
  and check the keyboard reopens on the composer. Pick a Claude reply and improve it.
