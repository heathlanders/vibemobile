# ADR 0027 — Scheduled prompts (unattended runs)

**Status:** Accepted (2026-10-07). Evidence: a real-SDK run through the scheduler's own tick
(a due schedule started a genuine session with no socket attached, ran its prompt to
completion, sent the `done` push and booked the next slot).

## Context

Mainstream harnesses can run a prompt on a timetable ("every weekday at 09:00 summarize CI").
VibeMobile had nothing like it. It is also the riskiest feature the daemon can have: it starts
model sessions — which can run commands and edit files — **while nobody is watching**, from
stored text, on a timer.

## Decision

A `schedules` table and a scheduler (`schedule.ts`) with a 30 s tick, exposed through bearer-gated
`/schedules` routes (list, create, patch, delete, run-now). A run is an **ordinary session** created
exactly like `POST /sessions`, so every existing control applies: permission gate, Auto-mode file
scope, audit, push, live-session cap, disk guard. On top of that the unattended case is bounded:

1. **Safe by default.** The run's mode defaults to `ask`: every tool call waits for approval on
   the phone (a push is sent). `plan` is also offered. `auto` (no asking) must be chosen
   explicitly per schedule; the app asks for confirmation and labels the row, and the audit
   (`schedule.run`) records the mode. `bypassPermissions` and any other mode string are rejected.
2. **One at a time.** If the previous run of the same schedule is still mid-turn the slot is
   skipped (`skipped: the previous run is still going`) — runs never pile up.
3. **Caps apply.** `VIBE_MAX_CLAUDE` live sessions and `disk.min_free_gb` (ADR 0026) → the run
   *waits* and retries each tick until it would count as missed; at most 50 schedules; prompt
   ≤ 8000 chars, title ≤ 120.
4. **Never fire late and unexpectedly.** A run that is more than 2 h overdue (daemon was down)
   is recorded `missed` and the schedule moves to its next slot.
5. **Bounded targets.** The project must still exist and be inside `VIBE_PROJECT_ROOTS`.
6. **Strict input.** Unknown fields, bad times (`HH:MM`), bad weekdays, past one-time instants,
   non-boolean flags, NUL in text → `400`. Times are the server's local clock; the API reports
   the zone and UTC offset so the phone can display and enter them correctly.
7. **Audited.** `schedule.create|update|delete|run|missed|skipped`.
8. **Failure never takes the daemon down.** The tick is wrapped; if starting the engine throws,
   the half-made session row is removed and the failure recorded on the schedule.

## Consequences

- Residual risk, stated plainly: a schedule in `auto` mode is autonomous code execution on a
  timer. It is exactly as powerful as the user typing that prompt in Auto mode, minus the
  watching. The defaults, the explicit confirmation and the audit trail are the mitigations; the
  free-space and session caps are the blast-radius limits.
- A run uses the project's checkout directly (no worktree); concurrent edits with a human are
  possible. Isolating runs in a worktree is a possible follow-up (ADR 0022).
- The result of a run is an ordinary chat ("⏰ <title>"); there is no separate report. The
  schedule row keeps the last status and links to the last session.
- Scheduling is in-process: if the daemon is stopped, runs are missed (see 4), not queued.
- Not done: cron expressions, per-run output retention, a "notify me with the result" digest.
