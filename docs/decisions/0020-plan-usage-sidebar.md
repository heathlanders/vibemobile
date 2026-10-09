# ADR 0020 — Always-on Max-plan usage meter

**Status:** Accepted (2026-10-06).

## Context

On a Max subscription, the real budget is the rolling **5-hour window** and
the **weekly limits**, not dollars. The goal is to use as much of each window
as possible before it resets.

The daemon already read these limits (`usage.ts`, from `GET /api/oauth/usage`
with the CLI-login OAuth token). But it only pushed them as a `usage` frame
inside an open chat, so there was no way to see them at a glance.

We also tried the Agent SDK's `usage_EXPERIMENTAL_…` control call (SDK 0.3.291).
It returned `rate_limits: null` because it hits the same endpoint, which was
answering 429. The endpoint is tightly rate-limited, so polling must stay gentle.

## Decision

1. **`GET /usage/plan`** returns `{ usage, fetchedAt }`.
   - It's bearer-gated and read-only.
   - It shares `getUsage()`'s 5-minute cache and backoff, so client polling
     never adds load on the upstream endpoint.
   - `usage` is null until a first good fetch, or always in gateway mode.
   - The token never leaves the daemon.
2. **`PlanUsageMeter`** (`features/usage/presentation/`) polls every 2 minutes
   and renders nothing until there's data.
   - **Desktop:** pinned to the bottom of the NavigationRail (`trailingAtBottom`),
     showing the 5h and 7d all-models bars. Tapping it opens Usage.
   - **Phone:** a strip above the dashboard grid. Tapping it opens Usage.
   - **Usage page:** a full "Plan limits" section with every weekly limit,
     including per-model ones.
3. **Pace tick.** Each bar gets a marker at the fraction of the window already
   gone (from `resetsAt`).
   - Usage left of the tick is capacity not used yet.
   - The full view says "Under pace — room to push", "On pace", or "Over pace",
     with a ±10-point dead band.

## Consequences

- The meters can be up to about 5 minutes behind, more while the endpoint is
  returning 429. The full view shows "As of Xm ago" when the data is over
  15 minutes old.
- **Done (2026-10-06):** live SDK sessions' `rate_limit_event` feeds the cache
  (`ingestRateLimit`). Real shape (SDK 0.3.291, not in its `.d.ts`):
  `rate_limit_info.unifiedWindows.{five_hour,seven_day}` =
  `{ utilization: 0..1, resetsAt: epoch s }`, matching the endpoint's
  `five_hour`/`seven_day` (0.09 ↔ 9 %). An event updates Session + All models
  and restarts the 5-minute TTL, so the endpoint isn't called while work is
  going on. Per-model weekly limits and severity aren't in the event, so the
  endpoint is still refetched at least every 30 minutes. Gateway mode ignores
  events.
- **Done (2026-10-06):** "use it before it resets" push. `startUsageNudger`
  checks `getUsage()` every 5 minutes (through the same cache and backoff, so no
  extra endpoint load) and sends a content-free `usage_reset` push (ADR 0013)
  when a window is close to its reset with most of it unused:
  - Session (5 h): under 30 minutes left and under 50 % used.
  - Weekly All models: under 12 hours left and under 50 % used.
  - Per-model weekly limits never trigger it.

  One push per window reset. The key is the reset time rounded to the minute,
  because the endpoint and the SDK event report the same reset a few hundred ms
  apart. The qualifying window goes to the audit log as `usage.nudge`; the phone
  note just says to open the app.
