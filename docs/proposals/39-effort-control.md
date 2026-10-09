# 39 — Reasoning effort control

**Status:** implemented (daemon + app + tests 2026-10-07; on-device check pending)

Pick how hard the model thinks — per session, changeable mid-conversation. Evidence:
[M11 spike](../spikes/M11-spike-effort.md). Pairs with [thinking blocks](36-thinking-blocks.md)
(see the reasoning) and [live model switch](37-live-model-switch.md).

- **Wire** ([claude-ws.md](../protocols/claude-ws.md)): client → `{t:"set_effort", effort}`
  (`"low"|"medium"|"high"|"xhigh"|"max"`, or `null` for the model's default); server →
  `{t:"effort", effort, levels}` on attach and after each successful change. The native
  engine never sends it, so the app hides the entry there.
- **Daemon** (`claude.ts`): `sessions.effort` is read in the constructor (so attach reports it
  whichever of attach/start runs first) and passed as the `effort` start option;
  `setEffort` whitelists the level, calls `Query.applyFlagSettings({effortLevel})`, persists,
  audits `session.effort` and announces. An unknown level, a no-op, a stopped session or an
  SDK refusal changes nothing.
- **App:** "Effort… (high)" in the chat menu → `EffortSheet` (Default + the five levels with
  one-line hints, "applies from the next message"). Scrollable: six two-line rows overflow a
  default bottom sheet.
- **Cost:** higher effort thinks longer — slower and costlier; the sheet says so. Models
  without effort support ignore it (SDK behaviour).

Out of scope: a default effort per project or per task profile, showing the effective effort
the SDK downgraded to, auto-selecting effort from the prompt.

Tests: `vibe-daemon/src/effort.test.ts`, `app/test/effort_test.dart`.
