# 69 — Daemon reliability and operations

**Status:** accepted 2026-11-19 · from the 2026-11-19 project review · daemon + `deploy/`

## Problem

The daemon can be crashed by one bad frame, loses sessions it should keep, and tells nobody when
something fails. Findings read in code on 2026-11-19 (v1.0.40); "inferred" ones were not reproduced
and need a repro first.

| # | Finding | Where |
|---|---------|-------|
| R1 | PTY socket handler runs `JSON.parse` and `term.resize` unguarded; no `uncaughtException` handler exists. One malformed frame kills the daemon and every SDK subprocess. The `/tty` twin is guarded. | `vibe-daemon/src/pty-ws.ts:54-55` (compare `session-ws.ts:221-227`) |
| R2 | Idle reaper stops any session with no sockets and 30 quiet minutes, including one waiting on AskUserQuestion or running a long silent Bash. | `vibe-daemon/src/claude.ts:426-428`, `claude.ts:597-599` |
| R3 | When the SDK loop throws, the session stays in the registry; `getOrStart` reuses it and `pushUser` queues into a finished generator. Status shows "running" forever. (read, not reproduced) | `claude.ts:703-713`, `session-ws.ts:32-33` |
| R4 | (inferred) tmux-backed terminals die on daemon restart: the tmux server is a child in the daemon's cgroup and the unit kills the whole cgroup. Contradicts ADR 0004. | `vibe-daemon/src/tmux.ts:86`, `external.ts:72-74` |
| R5 | `Fastify({ logger: false })`, no `setErrorHandler`, no SIGTERM handler. 500s are logged nowhere; shutdown is abrupt. `/health` returns a constant. | `vibe-daemon/src/app.ts:80` |
| R6 | Audit log stores session id + tool name, not the command. `docs/security.md` says "audit log every executed command". Command text lives only in `messages.tool_json`, deleted with the session. | `vibe-daemon/src/permission-gate.ts:62` |
| R7 | No retention or vacuum. `permission.auto_allow` and `projects.scan` dominate `events`. No DB backup. | `vibe-daemon/src/db.ts` |
| R8 | `messages` has no index on `session_id`; every attach scans the table, every tool result does `LIKE '%id%'`. | `db.ts:59-66`, `claude.ts:381`, `claude.ts:877` |
| R9 | Auto-allow is the default mode and Bash is unscoped: injected text in a repo or web page gets an unattended shell. | `vibe-daemon/src/engine.ts:15`, `file-scope.ts:6` |
| R10 | `send()` never checks `bufferedAmount`; a slow phone plus heavy output grows daemon memory. | `pty-ws.ts:39-41`, `claude.ts:923-925` |
| R11 | The unit in `deploy/` is not what runs: the live unit lacks the memory caps and uses Node 18. Runs TS through `tsx` with no build. | `vibe-daemon/deploy/vibe-daemon.service`, PLAN.md §7 |
| R12 | 18 spike files and `serve-pty.ts` live in `src/` beside production code. | `vibe-daemon/src/` |

## Proposal

Order = value per hour. One PR per step.

1. **R1.** try/catch + cols/rows validation in `pty-ws.ts`; add process-level
   `uncaughtException`/`unhandledRejection` handlers that log and keep running.
2. **R5.** Turn on the Fastify logger (pino → stdout → journald), add `setErrorHandler`, add
   SIGTERM/SIGINT graceful stop (close sockets 1012, close DB). `/health` returns uptime, live
   session count, DB ok.
3. **R2.** Reaper skips a session while a turn is running or a permission/dialog is pending.
4. **R3.** Write a test that makes the fake SDK throw mid-turn; on loop exit remove the session
   from the registry and close its sockets with 1012.
5. **R8 + R7.** Add `CREATE INDEX messages_session ON messages(session_id)` and a `tool_use_id`
   column to replace the LIKE scan. Add a daily prune (keep `events` 90 days; keep
   `permission.auto_allow`/`projects.scan` 7 days) and `VACUUM` after a large prune. Add a nightly
   `db.backup()` to a configured dir, keep 7.
6. **R6.** Log the first 200 chars of the Bash command (or tool input summary) in the audit event;
   update `docs/security.md` to match what is true.
7. **R4.** Spike first: restart the daemon with a terminal open, record whether tmux survives. If
   not, start tmux via `systemd-run --user --scope` (the pattern already used in `merge-queue.ts`).
8. **R11.** Commit the unit that is really installed, with `MemoryHigh`/`MemoryMax`/`TasksMax`.
   Move to Node 20+: rebuild native modules under the same Node the unit uses (hazard described in
   PLAN.md §7). Do this step last in a session — restarting the daemon ends the session.
9. **R10.** Above a `bufferedAmount` high-water mark, pause the PTY (`term.pause()`) and drop
   stream deltas for chat (history replays on reconnect).
10. **R9.** Keep Auto as default; add a small deny/ask list for Bash in Auto mode (network fetch
    piped to a shell, `rm -rf` outside the project, writes to `~/.ssh`, `~/.config/systemd`).
    Security-relevant: `reviewer` pass.
11. **R12.** Move spikes to `vibe-daemon/spikes/` (not under `src/`).

## Wire / schema impact

- `messages.tool_use_id TEXT` + two indexes. `events` gains truncated command text.
- No client change except `/health` consumers (check `app/lib/features/system/`).

## Acceptance

- Test: malformed and non-JSON frames on the PTY socket do not throw.
- Test: a detached session with a pending dialog survives the reaper; an idle one is reaped.
- Test: SDK loop throw → session gone from registry, next attach starts fresh.
- Test: prune removes old rows, keeps recent ones; backup file opens as a valid DB.
- Spike doc for R4 in `docs/spikes/`.
- `cd vibe-daemon && npm test` green. After R11: `/health` ok and one real chat + one terminal checked.

## What shipped

- **R1** (2026-11-19). `pty-ws.ts` wraps the resize parse in try/catch and only resizes for
  integer cols/rows in 1..1000. `server.ts` logs `uncaughtException`/`unhandledRejection` and
  keeps running. Test: `pty-ws.test.ts` "malformed resize frames are ignored" sends non-JSON,
  empty, `null`, `{}`, negative, string and huge sizes plus an empty frame, then checks input
  still echoes; on the old code the test hangs. Process handlers have no test (they live in the
  entrypoint). Found on the way, not fixed: the route adds its `message` listener after
  `await tmux.hasSession/detachOthers`, so frames sent right after `open` are dropped; the app's
  first resize can be lost (the test resends until the PTY draws).
- **R5** (2026-11-19). Fastify logger on in `server.ts` only (pino JSON → stdout → journald;
  request lines off because `/system` polls every few seconds). `setErrorHandler`: a 5xx is logged
  with its stack and answered `{error: "internal error"}` (no message: it can carry paths or
  command text); a 4xx answers `{error: <message>}`. `/health` (still public) returns
  `{ok, db, uptimeSec, sessions}`, 503 when the DB stops answering. SIGTERM/SIGINT run
  `stopDaemon` (`shutdown.ts`): every WS gets 1012, in-flight requests finish, the DB closes;
  forced exit after 10 s. Tests: `health.test.ts` (health + 503, 500 without the message, stop →
  1012 + DB closed; all red on old code). Checked by hand: a scratch instance (own DB, hook socket,
  tmux socket, port 18787) served the new `/health` and exited cleanly on SIGTERM. Not live until
  the daemon restarts.
- **R2** (2026-11-19). `ClaudeSession.isReapable` is false while a turn runs (`busy()`) or a
  permission/dialog is pending, whatever `lastActivityMs` says: a long silent Bash or an unanswered
  question sends no SDK traffic, so the old check reaped live turns. Test: `claude.test.ts` (fake
  SDK blocks mid-turn: detached + quiet → not reapable; after `result` → reapable; red on old code).
  Not changed: `NativeSession.isReapable` has the same shape; native turns stream from the API, but
  a slow native tool call would hit the same gap.
- **R3** (2026-11-19). Reproduced: a fake SDK that throws mid-turn left the session in the
  registry; the socket stayed open and every later turn queued into a dead loop. Now when
  `consume()` throws (and the session wasn't stopped) it sends the `error` frame, stops with
  1012 (clients reconnect) and calls `onEnded`, which `getOrStart` sets to drop it from the
  registry; the reattach starts a fresh session that resumes by `claude_session_id`. Test:
  `session-ws.test.ts` over a real socket (crash → error + 1012, gone from registry, reattach →
  new instance; old code hangs waiting for the close). Gap: a loop that *ends cleanly* while input
  is still open is not handled. The real SDK only ends when input closes, but the test fakes end
  after one turn, so covering it means reworking the shared fake.
