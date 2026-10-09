# ADR 0017 — Token/cost ledger and usage dashboard

**Status:** Accepted (2026-10-05). Roadmap phase 3 of [ADR 0015](0015-desktop-client.md).

## Context

The only spend figure so far was `sessions.total_cost_usd`. It was a running
total per session, it didn't split tokens into cached and uncached, and it
couldn't answer "where are my tokens going". Saving tokens means knowing cache
reuse, context size per turn, and which models do which work, all across
projects and over time.

## Decision

1. **A `usage_events` table**, one row per model per completed turn:
   - session and project
   - provider and model
   - uncached input tokens, output tokens, cache reads, cache writes
   - cost and timestamp

   No prompt text is stored. There's no foreign key to `sessions`, so history
   survives deleted sessions. It's added through the existing idempotent
   `CREATE TABLE IF NOT EXISTS`, so no migration runner is needed.
2. **Both engines record** through `spend.ts` `recordUsage()`.
   - **Claude:** writes one row per entry in the Agent SDK result's
     `modelUsage`, so a Haiku subagent shows up separately from the session's
     Opus. Cost is the SDK's `costUSD`, which on a Max plan is the
     API-equivalent figure, not a charge (the UI says so).
   - **Native:** writes the AI SDK's `totalUsage`, splitting cache reads out of
     input, priced via `priceFor` (ADR 0016).
3. **`GET /spend?group=model|project|provider|day&days=N`** (1–365, default
   30) returns `{ totals, rows }`.
   - The group is picked from a fixed allowlist of SQL expressions and is never
     interpolated; anything else gets a 400.
   - The route is read-only and bearer-gated.
4. **Usage page** (desktop rail, phone dashboard):
   - Headline tiles: cost, turns, tokens in/out, cache hit rate.
   - Spend per day as a single-series bar chart.
   - A ranked breakdown by model, project or provider.
   - Rule-based tips (`savingsTips`):
     - low cache reuse;
     - cache written more than read;
     - more than 150k tokens of context per turn on average;
     - expensive short turns on a big model.

   Each tip needs at least 10 turns of data before it fires.

## Consequences

- The ledger starts empty. Turns from before this change only count toward
  `total_cost_usd`, not the dashboard.
- Tips are heuristics with conservative thresholds, so a healthy ledger shows
  none.
- ~~**Next:** a tip about CLAUDE.md size, and per-session token detail in the
  chat header.~~ Done 2026-10-06:
  - `/spend?group=project` rows carry `claudeMdBytes`. The Usage page always
    fetches the by-project report, and `savingsTips` warns about a project
    whose root CLAUDE.md is over 40 KB (Claude Code's own warning threshold)
    and that has at least 10 turns.
  - `GET /spend/session/:id` → chat menu **Token usage** sheet: turns,
    uncached input, cache reads/writes, output, hit rate, average context per
    turn, cost, and per-model rows.
  - Only the root `CLAUDE.md` is measured; `@imports` and `.claude/CLAUDE.md`
    are not.

## Amendment (2026-10-08) — Claude-engine usage is recorded as deltas

The Agent SDK's `result.modelUsage` and `total_cost_usd` are **cumulative for the whole
conversation**, including across a `resume` in a new process (spike M16). The Claude engine
recorded them as per-turn figures, so the ledger and `sessions.total_cost_usd` were summed
~45× too high (recorded $51.8k vs ≈$1.1k real API-equivalent).

Fix: `spend.ts` `recordCumulative` / `cumulativeCostDelta` keep the last cumulative reading
per (session, model) in `usage_cumulative` and record only the increase (a lower reading
records nothing and re-baselines). `migrateLedgerToDeltas` runs once at startup: it differences
existing `provider='anthropic'` rows per (session, model), seeds the baselines, recomputes
`sessions.total_cost_usd`, and keeps the originals in `usage_events_cumulative_backup`
(which is also the "done" marker). Native-engine rows were already per-turn and are untouched.
