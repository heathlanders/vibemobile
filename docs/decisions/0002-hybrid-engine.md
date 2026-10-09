# ADR 0002 — Hybrid engine (Agent SDK + raw PTY)

**Status:** Accepted (2026-06-08)

## Context

The user does **not** use the Claude desktop app; they live in the terminal.
They want polished Claude-session management *and* true console parity ("as if
at my PC"). A pure chat UI loses TUI fidelity; a pure terminal loses native
mobile chat affordances (tap-to-approve, transcript, push).

## Decision

Run **both** engines side by side per project:

- **Claude engine** — `@anthropic-ai/claude-agent-sdk`. Headless
  (`stream-json`), one resumable `session_id` mapped to a project cwd, rendered
  as a native mobile chat UI.
- **PTY engine** — `node-pty` (optionally inside `tmux`). One pseudo-terminal
  per terminal tab, rendered by `xterm.dart`. Survives restarts when tmux-backed.

## Consequences

- Two transports to maintain (`WS /session/:id` JSON events; `WS /pty/:id`
  bytes). See [../protocols/pty-ws.md](../protocols/pty-ws.md).
- Auth model confirmed cheap: SDK reuses CLI login, no API key
  ([../spikes/M0-spike1-agent-sdk-auth.md](../spikes/M0-spike1-agent-sdk-auth.md)).
- TUI parity gaps (slash-command pickers render differently headless) get
  mapped into chat UI or fall back to the terminal tab (`PLAN.md §7`).
- Open: tmux-backed vs raw node-pty (durability vs simplicity) — decide in M2.
