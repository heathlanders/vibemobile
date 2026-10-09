# Protocol — M2 terminal reattach (drop-detect + reconnect)

How a terminal session survives a dropped WebSocket — the mobile client roams
networks (WiFi ↔ cellular), its IP changes, the socket dies, and it must
re-attach to the **live** session without losing state.

Builds on:
[ADR 0003 wire protocol](../decisions/0003-pty-ws-wire-protocol.md) ·
[ADR 0004 tmux-backed PTY](../decisions/0004-tmux-backed-pty.md) ·
[pty-ws.md](./pty-ws.md).

## Design invariant

**Reconnect adds no server→client framing.** The session lives in tmux
(ADR 0004), so on re-attach tmux redraws the current screen + scrollback for
free. That redraw *is* the catch-up. All reconnect signaling rides existing
channels:

- liveness → WebSocket control-frame ping/pong (out-of-band, not the byte stream)
- "session gone" → WebSocket **close code**
- screen state → tmux redraw on attach

server→client stays raw PTY bytes, exactly as ADR 0003 mandates. No new opcodes.

## Session lifecycle (changed from the M0 spike)

The spike spawned the shell **on WS connect** and killed it on close. M2 splits
creation from attachment so reconnect is just "attach again":

| Event | Action |
|-------|--------|
| Session created (REST `POST /sessions`, kind=`terminal`) | `tmux -L vibe new-session -d -s vibe-<id>` (detached create) + insert SQLite row |
| `WS /pty/:id` connect (first **or** reconnect — identical) | `tmux -L vibe has-session -t vibe-<id>` → if present, spawn node-pty wrapping `tmux -L vibe attach -t vibe-<id>`; if absent, close `4404` |
| WS close | **detach** (tmux client process exits) — session keeps running. Never `tmux kill-session` here |
| Session deleted (REST `DELETE /sessions/:id`) | `tmux -L vibe kill-session -t vibe-<id>` + remove row |

`-L vibe` = dedicated tmux socket, isolated from the user's own tmux (ADR 0004).
WS connect is now **pure attach** — first-open and reconnect take the same path.

## Drop detection

Mobile dead sockets hang half-open silently; both ends need an active heartbeat.

**Client (primary).** Set `dart:io` `WebSocket.pingInterval = 10s`
(via `web_socket_channel`). dart:io auto-sends ping frames and **closes the
socket if no pong arrives within the interval** → the client gets a close event
in ~10s instead of waiting on a multi-minute TCP timeout → triggers the
reconnect loop.

**Server (independent).** Heartbeat on the `ws` socket: ping every 15s, track
`isAlive` (set on `pong`). If a ping fires while `isAlive` is still false →
`socket.terminate()` → fires the `close` handler → **detach** the tmux client.
This reclaims the orphaned attach when the client vanished without a close frame.

App-level ping (reserved opcode `2`, pty-ws.md) is **not** used for liveness —
WS control frames do it without touching the byte stream. `2` stays reserved
(e.g. future RTT display).

## Reconnect sequence

```
 client                          daemon                       tmux (-L vibe)
   │  ── socket drops (IP roam) ──────────────────────────────────►  (session
   │                                                                   stays up,
   │  pingInterval fires, no pong → local close event                  detached)
   │
   │  backoff (0.5→1→2→4→8s, cap 10s, ±20% jitter)
   │
   │  WSS /pty/:id  + Bearer token  ──►  has-session vibe-<id>? ──►  yes
   │                                     spawn attach client    ──►  attach
   │  ◄──────────── raw bytes: tmux redraws screen + scrollback ──────┘
   │
   │  ── opcode 1: resize {cols,rows} (current viewport) ──►  pty.resize
   │  ◄──────────── redraw at new size ───────────────────
   │  (back to live: opcode 0 input ↔ raw output)
```

Steps:

1. Client detects close (pong timeout or clean close).
2. Inspect close code (table below) → reconnect or surface terminal error.
3. Reconnect loop: exponential backoff with jitter, same **stable** `:id`.
4. Server `has-session` → attach the live tmux session (or `4404`).
5. **Client sends resize first thing** after attach (pty-ws.md rule) — the tmux
   window may have been sized by a prior client or the detached default.
6. tmux redraw brings the terminal current. Resume normal input/output.

## Close codes (server → client)

| Code | Meaning | Client reaction |
|------|---------|-----------------|
| `1000` | Normal — user closed the tab | Stop. No reconnect |
| `1006` | Abnormal (transport died, no close frame) | Reconnect with backoff |
| `1012` | Server restarting | Reconnect with backoff |
| `4401` | Auth failed / token expired | Re-auth first, **then** reconnect. No blind retry |
| `4404` | Session not found / ended (shell exited, or machine rebooted → tmux gone) | Stop. Surface "session ended" — do **not** silently resurrect |

`4xxx` are app-defined. The `4404` rule is why connect is **attach-only**, not
`new-session -A`: `-A` would resurrect a dead session as a fresh blank shell and
the user would never know their work ended. has-session + `4404` makes session
death explicit.

## Single live client (resize safety)

tmux sizes a window to the **smallest** attached client (ADR 0004). A flaky
reconnect can momentarily leave the stale attach plus the new one, shrinking the
screen. On every attach the server first evicts other clients of that session:

```
tmux -L vibe detach-client -s vibe-<id>   # drop any existing client
tmux -L vibe attach     -t vibe-<id>      # attach as the sole client
```

Enforces one live client per session — also the right default for M4 multi-device
(last attach wins). Belt-and-suspenders: `setw -g aggressive-resize on`.

## Catch-up bounds

No app-level replay buffer — tmux scrollback is the buffer. Set
`history-limit 10000` (default 2000) at session create so a long disconnect
doesn't lose backscroll. The visible screen is always restored on redraw; only
backscroll **beyond** `history-limit` is unrecoverable. Note this bound rather
than pretend it's infinite.

## Rules / gotchas

- The `:id` must be **stable** across reconnects (the SQLite session-row id,
  stored client-side). A reconnect that mints a new id orphans the tmux session.
- Connect is **attach-only**; sessions are created out-of-band (REST). Never
  create-on-connect — it defeats `4404` semantics.
- WS close → **detach**, never `kill-session`. Killing is only `DELETE /sessions`.
- Send resize immediately after every attach, not just the first connect.
- Don't put liveness on opcode `2`; use WS control-frame ping/pong so the byte
  stream stays pure (ADR 0003).
- tmux server (`-L vibe`) survives daemon restart but **not** a machine reboot —
  after reboot, `has-session` misses → `4404` → fresh session expected.

## Follow-ups

- Verify dart:io `pingInterval` reaches the peer through `tailscale serve` (WSS,
  ADR 0005) — proxies can swallow control frames; measure real drop-to-reconnect time.
- Decide whether the daemon marks a session `stale` in SQLite when `has-session`
  misses, so the dashboard greys it out vs. just failing the attach.
- Reconnect storm: cap concurrent reconnect attempts per device so a flapping
  network can't hammer the daemon (via `tailscale serve`).
