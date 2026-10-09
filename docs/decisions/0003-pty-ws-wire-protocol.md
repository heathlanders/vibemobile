# ADR 0003 — PTY↔WS wire protocol (ttyd-style framing)

**Status:** Accepted (2026-06-08) — proven in M0 spike 2.

## Context

The terminal tab needs a byte-accurate channel between `node-pty` on the server
and `xterm.dart` on the phone, plus out-of-band control (resize). `PLAN.md §8`
says study ttyd/vibetunnel patterns.

## Decision

Use **ttyd-style first-byte opcode framing** on the client→server direction;
server→client is raw output bytes.

- client → server: `<opcode byte><payload>`
  - `0` + utf8 bytes → keystroke input → `pty.write()`
  - `1` + JSON `{cols, rows}` → `pty.resize()`
- server → client: raw PTY output bytes, forwarded verbatim (binary frames).

Full spec: [../protocols/pty-ws.md](../protocols/pty-ws.md).

## Consequences

- Trivial to implement on both ends; `xterm.dart` writes opcode-prefixed frames
  and feeds raw inbound bytes straight to the terminal.
- Output is **not** line-framed — never string-match raw PTY bytes on `\n`
  alone (see spike 2 gotcha).
- Room to grow opcodes (e.g. `2` = ping, `3` = tmux control) without breaking
  the two existing ones.
- Alternative considered: JSON-wrap every frame (`{t,d}`). Rejected — doubles
  bytes on the hot path and needs base64 for binary.
