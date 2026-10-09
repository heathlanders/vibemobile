# ADR 0004 — tmux-backed PTY (sessions survive restart + reconnect)

**Status:** Accepted (2026-06-09)

## Context

`PLAN.md §7` left open: back the terminal PTY with **tmux** (session survives
daemon restart / socket drop) or use **raw node-pty** (PTY lives in the daemon
process). M2's reconnect requirement forces the choice: a mobile client roams
networks (WiFi ↔ cellular), so its IP changes and the WebSocket drops mid-session.
On reconnect the daemon must re-attach to a **live** terminal, not start a new
shell — and ideally redraw the prior screen.

The current M0 spike (`vibe-daemon/src/spike-pty.ts`) does
`socket.on("close") → term.kill()`: a dropped socket destroys the session. That
is correct for the spike, wrong for M2.

## Decision

Back every terminal session with **tmux**. node-pty wraps a tmux *client*, not a
shell directly:

```
pty.spawn('tmux', [
  '-L', 'vibe',                    // dedicated socket — never collide with the
                                   //   user's own tmux server
  'new-session', '-A',            // attach-or-create (idempotent reattach)
  '-s', `vibe-${id}`,             // one tmux session per terminal session id
  '-x', '80', '-y', '24',
])
```

- The shell runs inside the tmux session on the tmux server process, decoupled
  from the daemon and from any single WebSocket.
- **Socket close → detach, not kill.** Send the tmux detach (or just let the
  client process exit); the session keeps running. Replaces the spike's
  `close → term.kill()`.
- **Reconnect → re-attach by id.** Same `new-session -A -s vibe-${id}` re-attaches
  the live session; tmux redraws the current screen + scrollback automatically —
  no server-side replay buffer needed.
- Wire protocol is **unchanged** (ADR 0003 / `protocols/pty-ws.md`): raw bytes
  both directions. tmux output is just more raw PTY bytes.

## Consequences

- Sessions survive socket drop (IP roam), daemon restart, and daemon crash —
  satisfies `PLAN.md:44`. Closes the `tmux dependency` open question in
  `PLAN.md §7`.
- Free scrollback replay on reattach; no in-daemon orphan-PTY map or ring buffer
  to maintain (the raw-node-pty alternative would have to reimplement both, and
  still lose everything on restart).
- Adds a server dependency on tmux (present: 3.2a). Mitigated by `-L vibe`
  (dedicated socket, isolated from the user's tmux).
- **Aggregate resize gotcha:** tmux sizes a window to the *smallest* attached
  client. Two devices on one session shrink it to the minimum. Mitigation:
  `setw -g aggressive-resize on`, and/or detach the old client when a new one
  attaches (one live client per session). Revisit under M4 multi-device.
- Lifecycle change is the only daemon delta vs. the spike; the M2 reattach
  protocol (ping/pong drop-detection, resize-on-reconnect) builds on this.
- Alternative considered: **raw node-pty** with daemon-side session map +
  scrollback buffer. Rejected — reimplements tmux in-memory, dies on daemon
  restart, more code for strictly less durability.
