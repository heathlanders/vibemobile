# Proposal 14 — Jump to permission

## Why
A `permission_request` can arrive while you're scrolled up in a long transcript. The
card pins to the bottom of the chat but is easy to miss — the turn stalls (120s
timeout → auto-deny) with no obvious prompt.

## Sketch
When a permission (or dialog) arrives, surface a banner / pulse and auto-scroll or
offer a "jump to request" affordance. Builds on proposal 13's scroll tracking.

## Impact
- **Wire:** none (reacts to existing `permission_request` / dialog frames).
- **Schema:** none.
- **Client:** on `pendingPermission`/`pendingDialog` set, scroll into view +
  highlight; optional haptic. Pairs with [13](13-scroll-unread.md).

## Open
- Auto-scroll vs nudge-only (don't yank if the user is mid-read).
- Tie to the 120s deny timeout — show a countdown on the card.
