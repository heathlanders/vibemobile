# M0 Spike 2 — PTY ↔ WS round-trip + resize

**Status:** ✅ Passed (2026-06-08)
**Code:** `vibe-daemon/src/spike-pty.ts`
**Run:** `cd vibe-daemon && npm run spike:pty`

## Risk being killed

`PLAN.md §6`: can we pipe a real `node-pty` shell over a WebSocket — the exact
wire `xterm.dart` will speak — including terminal resize, on a localhost-only
bind? This is the spine of M2 (terminal tab).

## What the spike does

Self-contained, verifiable **headless** (no Flutter yet):

1. Fastify + `@fastify/websocket` server, bound `127.0.0.1:8788`, route
   `GET /pty/:id` → spawns `node-pty` on `$SHELL`.
2. An **in-process WS client** connects, sends a resize, then types
   `echo VIBE_SPIKE""_OK` and waits to see the resolved marker `VIBE_SPIKE_OK`
   echoed back from the real shell.
3. Exit 0 = marker seen + resize acked; exit 1 = failed.

## Wire protocol used

See [../protocols/pty-ws.md](../protocols/pty-ws.md). ttyd-style:

- client → server: first byte opcode — `0`=input bytes, `1`=resize JSON.
- server → client: raw PTY output bytes, forwarded verbatim.

## Result

```
[server] listening ws://127.0.0.1:8788/pty/:id
[server] pty spawned pid=… session=selftest
[server] resize -> 120x40
[client] saw marker in pty output ✓
[server] pty exit code=0
[spike] DONE. node-pty <-> WS round-trip + resize OK
```

## Gotcha found (recorded so we don't repeat it)

PTY output lines are terminated with `\r\n` and the command-output line was
preceded by a bare `\r` (after a `\x1b[?2004l` bracketed-paste-off sequence),
**not** `\n`. A naive `(^|\n)MARKER` matcher missed it. Real clients render
raw bytes through a terminal emulator (xterm.dart), so this only bites
server-side string matching — but worth knowing: **don't line-match raw PTY
bytes on `\n` alone.**

## Follow-ups

- ~~Run the same WS through the **Cloudflare tunnel** (WSS).~~ Done in M0 and
  later superseded by `tailscale serve` (ADR 0005).
- ~~Wrap PTY in **tmux** so sessions survive daemon restart.~~ Done (ADR 0004).
- Forward `onExit` / close cleanly to the client UI.
