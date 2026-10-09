# Proposal 11 — Retry / edit last user turn

## Why
A typo or bad phrasing means starting a new turn manually. No resend, no edit. Quick
iteration on prompts is a core chat affordance.

## Sketch
Long-press a user message → **Retry** (resend verbatim) or **Edit** (prefill
composer, send as a new turn). The superseded turn is marked in the UI
(dimmed/"edited"). No history rewrite — appends a new `user` turn; Claude's context
already includes the prior exchange.

## Impact
- **Wire:** none (reuses `user` frame).
- **Schema:** optional `superseded` flag on the `messages` row for render; or
  client-only marking.
- **Client:** long-press menu on user bubbles; composer prefill; dim superseded.

## Open
- Whether to visually fold the superseded turn + its reply, or just dim.
- "Edit" appends (no rollback) — confirm we don't try to truncate SDK history
  (the SDK transcript is append-only).
