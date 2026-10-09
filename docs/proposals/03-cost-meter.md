# Proposal 03 — Cost / token meter

## Why
Live spend visibility per session; catch runaway loops.

## Sketch
`result` frame already carries `cost` (`total_cost_usd`)
([claude-ws.md](../protocols/claude-ws.md)). Accumulate per session, show a badge in
the chat header. Persist running total on the `sessions` row.

## Impact
- **Wire:** none (uses `result.cost`). Optional: add `tokens` to `result` if the SDK
  exposes input/output counts.
- **Schema:** `sessions.total_cost_usd` column (+ migration). Already audit each turn
  in `events` — add cost to that row.
- **Client:** header badge, per-session total.

## Open
- Per-turn vs cumulative display (show both: turn + session total).
- Cross-session/project rollup → defer to dashboard (M4).
