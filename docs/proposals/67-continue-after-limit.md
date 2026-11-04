# 67 — Continue after the usage limit resets

**Status:** built 2026-11-04 (v1: per-session toggle; schedules field later) · on-device + real-limit check pending · daemon: limit detection in `claude.ts`, one persisted continuation per session, two push types; client: "continues at HH:MM" banner

## Problem

From the user's Notes: long prompts that run for hours, overnight, stop when they hit the
5-hour usage limit, and nothing picks them back up until the user comes back. They want
VibeMobile to continue the work when the window resets, so overnight runs keep going.

Today the daemon reads the SDK's `rate_limit_event` only for the usage meter
(`claude.ts` → `ingestRateLimit`). A rejected turn ends in a normal `result`; the session
goes idle. Schedules (proposal 44 / ADR 0027) fire a slot once and never retry.

## Prior art

- **Claude Code itself (v2.1.234+):** interactive subscription sessions wait for the reset and
  send a fixed "pick up where you stopped" prompt (`autoContinueAtUsageLimit`, default on).
  Stops after 3 continuations in a row, won't wait when the reset is more than 24 h away, keeps
  normal permission prompts, and loses the wait if the process exits. The docs say it is
  **not available in `-p` runs or background sessions**. VibeMobile's chat engine is the Agent
  SDK, so it probably sits outside this (unverified; see Spike).
- **`/goal`:** keeps working until a condition holds, works with `-p`, pauses at the limit. This
  covers "loop a long prompt", so no custom re-prompt loop is needed.
- **Community wrappers:** `terryso/claude-auto-resume`, `benbasha/Claude-Autopilot`,
  `frankbria/ralph-claude-code` (circuit breaker, exit gate). The popular ones run with
  permissions skipped. Ralph had a bug where a timeout was read as the 5 h limit.
- **Terminal sessions** on the box are interactive CLI, so they already get the built-in wait.

## Not doing: "burn the credits"

- The weekly caps were added because of accounts running Claude Code 24/7.
- Spending every 5 h window overnight uses up the weekly allowance the user needs during the day.
- The Consumer Terms forbid automated access "except … where we otherwise explicitly permit it".
  Anthropic ships auto-continue, `/goal` and scheduled tasks, so continuing *work the user
  started* matches what Anthropic itself ships. A loop that exists only to spend quota does not.
- The usage-screen idea (proposal 64, O2) shows headroom instead.

## Proposal

**Spike folded into the build.** The SDK types already give the structured fields
(`SDKRateLimitInfo.status/rateLimitType/resetsAt`, sdk.d.ts), and forcing a real limit burns quota.
So v1 logs the raw rejected event + following `result` the first time one happens, and the tick
skips a continuation whose session is already busy (covers the SDK resuming by itself). Original
spike plan: Drive a real SDK session into a rejection (or capture one
overnight). Record:
- the `rate_limit_event` (`status: rejected`, `rateLimitType`, `resetsAt`);
- the `result` subtype and error;
- whether the query survives;
- whether the SDK's internal "auto-resume continuations" fire on their own.

If they fire, the remaining work is only the push and the banner.

**If not, build:**
1. On `rate_limit_event` with `status: "rejected"`, `rateLimitType: "five_hour"` and a `resetsAt`
   less than 24 h away, store one continuation on the session row: `continue_at = resetsAt + 1–3
   min jitter`, `continue_count`.
2. A 30 s tick (same as schedules) fires it: `getOrStart` and then `pushUser` with a fixed prompt
   ("The usage limit reset. Continue where you stopped."). The tick skips a session that is busy
   or that the user is driving. Because the continuation is in SQLite, it survives a daemon
   restart, which the built-in wait does not.
3. Bounds, matching Claude Code:
   - at most 3 continuations in a row, reset by any user turn;
   - weekly (`seven_day`) rejections are never continued;
   - the session's own permission mode is kept: an `ask` session stalls on the first tool call
     and pushes `permission` as it does today, and `auto` is the user's explicit choice;
   - the live-session cap and the disk guard apply.
4. Per-session opt-in: a "Continue after limit" toggle in the session menu, plus a field on
   schedules. Off by default.
5. Push `limit_paused` (with the reset time on the banner) and `limit_continued`/`limit_gave_up`.
   These are content-free, like the existing types. Each one is audited.
6. Long loops go through `/goal` in the prompt or in a Schedule. No VibeMobile loop engine.

## Wire / schema impact

- `sessions`: `continue_after_limit INTEGER DEFAULT 0`, `continue_at TEXT`, `continue_count INTEGER DEFAULT 0`.
- `schedules`: `continue_after_limit`.
- `PushType` += `limit_paused`, `limit_continued`, `limit_gave_up`, handled in the client switch (`push_service.dart`).
- WS frame `limit_wait {resetsAt}` so an attached client shows the banner.

## Risks

- **Misdetection.** Act only on the structured `status: rejected` field, never on text matching.
- **Unattended `auto` mode.** This is an existing risk (security.md row 22). Continuing makes it last longer, so the toggle's copy should say so.
- **Context drift** after compaction on very long runs. The 3-continuation cap bounds this.
- **ToS.** If Anthropic's guidance on unattended SDK use changes, the toggle is the kill switch.

## Acceptance

- The spike result is recorded in `docs/spikes/`.
- A test feeds a rejected `rate_limit_event` and gets a stored continuation. Another feeds a weekly rejection and gets nothing. The 4th continuation in a row gives up and sends a push.
- A real overnight run that hit the limit resumed by itself after the reset and finished.
