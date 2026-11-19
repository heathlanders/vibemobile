# R4 spike — do tmux terminals survive a daemon restart?

**Date:** 2026-11-19 · **Proposal:** [69](../proposals/69-daemon-reliability-ops.md) R4 · **ADR:** 0004

## Question

ADR 0004 promises terminals outlive the daemon. The unit uses the default
`KillMode=control-group`, and the daemon forks the tmux server with its first `new-session`.
Does `systemctl --user restart vibe-daemon` kill every terminal?

## Method

A scratch daemon as a transient user unit (same `KillMode=control-group` as the real one), with
its own DB, hook socket, tmux socket (`VIBE_TMUX_SOCKET`) and port, so the live daemon was never
touched:

1. `systemd-run --user --unit=<scratch> … node … src/server.ts`.
2. Pair, create a terminal session over REST, read the tmux server's `/proc/<pid>/cgroup`.
3. `systemctl --user restart <scratch>`, then `tmux -L <sock> ls` and the session row's status.

## Result

| | tmux server cgroup | after restart |
|---|---|---|
| Before (plain spawn) | `…/app.slice/<scratch>.service` | `no server running`; the row swept to `stale` |
| After (`systemd-run --user --scope`) | `…/app.slice/run-<id>.scope` | session listed, row `live`; a WebSocket reattach got the same shell (`echo` answered) |

So yes: before the fix every daemon restart killed every terminal.

## Fix

`tmux.ts` `createSession` runs `new-session` inside `systemd-run --user --scope --collect`, so the
forked server lives in its own transient scope. Falls back to a plain spawn when user systemd is
missing (CI) or `VIBE_TMUX_SCOPE=0`. Test: `tmux.test.ts` checks the server's cgroup is a
`.scope`, not the caller's (skipped without user systemd).

## Not covered

- An already-running tmux server keeps its old cgroup until it exits: the first restart after
  deploying this still kills terminals that existed before it.
- Reboot still ends every terminal, by design (`sweepStale`).
