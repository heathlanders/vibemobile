# Protocol — PTY ↔ WS

The wire between `node-pty` (server) and `xterm.dart` (client) for the terminal
tab. Decision: [../decisions/0003-pty-ws-wire-protocol.md](../decisions/0003-pty-ws-wire-protocol.md).
Proven: [../spikes/M0-spike2-pty-ws-roundtrip.md](../spikes/M0-spike2-pty-ws-roundtrip.md).

## Endpoint

```
WS /pty/:id          (:id = terminal session id)
```

Daemon binds localhost only; reached over the tailnet via `tailscale serve`
(ADR 0005) as `wss://<machine>.<tailnet>.ts.net/pty/:id`. Bearer token required
(see auth, M1).

## Frames

### client → server

First byte is an **opcode**; the rest is the payload.

| Opcode | Meaning  | Payload                         | Server action      |
|--------|----------|---------------------------------|--------------------|
| `0`    | input    | utf8 keystroke bytes            | `pty.write(bytes)` |
| `1`    | resize   | JSON `{"cols":N,"rows":N}`      | `pty.resize(c,r)`  |

Reserved for later: `2` ping, `3` tmux control. Unknown opcodes are ignored.

### server → client

Raw PTY output bytes, forwarded verbatim as binary frames. The client feeds
them straight into the terminal emulator — **no framing, no line processing.**

## Lifecycle

> **M2 supersedes this for terminal sessions.** With tmux-backed PTYs
> ([ADR 0004](../decisions/0004-tmux-backed-pty.md)) the daemon **attaches** on
> connect and **detaches** on close — it does not spawn-on-connect or kill-on-close.
> See [reattach.md](./reattach.md). The flow below describes the M0 spike.

- On connect: server spawns the PTY (`$SHELL`, cwd = project dir, 80×24 default
  until first resize).
- PTY `onExit` → server closes the socket.
- Socket `close` → server kills the PTY.

## Rules / gotchas

- Output is a raw byte stream, **not** newline-framed. Never `split('\n')` or
  line-match it server-side (spike 2: output line was `\r`-prefixed after a
  `\x1b[?2004l` sequence).
- Send an initial resize right after connect so the PTY matches the device
  viewport before the first render.
- Keep input as discrete frames per keystroke/paste chunk; don't buffer-merge
  across control opcodes.
