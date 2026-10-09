# Proposal 13 — Scroll-to-bottom + unread marker

## Why
The chat force-jumps to bottom on every frame (`_autoScroll`). If you scroll up to
read history while a reply streams, you get yanked down. No "new messages" cue.

## Sketch
Only auto-scroll when already pinned to the bottom. When scrolled up, show a
floating **scroll-to-bottom** FAB with an unread count; tapping jumps down. Track
pinned state from the `ScrollController` offset.

## Impact
- **Wire:** none.
- **Schema:** none.
- **Client:** gate `_autoScroll` on "at bottom"; FAB + unread counter in
  `ChatScreen` (chat_screen.dart:47).

## Open
- Unread = frames since user scrolled up, or just a dot.
- Threshold (px) for "at bottom".
