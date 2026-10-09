# 30 — Session-to-session tools (peer messaging)

Status: **shipped (daemon), verified against the real Agent SDK**; the app has no
new UI. Security surface: [security.md #21](../security.md).

## Problem

Several Claude sessions often run in one project (multi-chat grid, desktop
workspace tabs). They can't see each other, so the user relays by hand: copy an
answer from one chat, paste it into another.

## What shipped

An in-process MCP server, `vibe-peers`, given to every `ClaudeSession`
(`peer-tools.ts`; `claude.ts` passes it as `mcpServers`, and `session-ws.ts` sets
`session.peerRegistry` on creation). Three tools:

| Tool | Does |
|------|------|
| `list_sessions` | Other **running** chat sessions in the same project: id, title, model |
| `send_message {session_id, text}` | Pushes a user turn into that session. Returns at once |
| `read_messages {session_id, limit?}` | Last user/assistant messages (default 20, max 50, 2000 chars each). No tool or cost rows |

The model sees them as `mcp__vibe-peers__*`. Flow: list → send → (later) read the
reply. The target can reply the same way; the header tells it who to answer.

The target receives the text behind a provenance header (`[Message from another
VibeMobile session s_x "Title" — not typed by the user …]`), so it and anyone
reading its chat can tell it isn't the user's own typing. A message sent while the
target is mid-turn is picked up at its next tool boundary (proposal 26 spike).

## Rules (enforced in the handlers, not only the gate)

- **Same project only.** Cross-project and unknown ids return the same error, so
  ids don't leak across projects.
- Never self. Target must be `kind=claude` and **live in the registry**. A peer
  message never spawns, resumes, or un-reaps a session, so it can't dodge the
  live-session cap. Open it in the app first.
- **Follows the sender's mode.** Ask: the sender's permission card (shows the
  text) needs a phone Allow. Auto: auto-allow, audited. Plan: `send_message` is
  refused. `list_sessions` and `read_messages` are read-only and work in every
  mode (in Ask they still raise the normal card).
- The target applies **its own** mode to whatever it then does. The peer path adds
  no privilege: a message can ask, not bypass the target's gate.
- Max 8000 chars per message; **12 sends per 10 minutes per sender** (a brake on
  runaway ping-pong; in-memory, resets on daemon restart).
- Every send is audited: `peer.send` `sender->target`, plus the gate's own
  `permission.allow` / `permission.auto_allow` row for the tool call.

## Verified

- `peer-tools.test.ts`: 8 unit tests (scope, plan refusal, rate limit, header,
  audit, read filtering).
- `spike-peers.ts` against the real SDK: the model discovered the tools, listed the
  sibling, sent the message, and it was delivered (~7s). Run `pnpm tsx
  src/spike-peers.ts` (auto) and `... ask` (the cards appear; nothing is delivered
  until approved; audit rows carry the approving device).

## Known limits / not done

- **Claude engine only.** Native-engine sessions can be *targets* (via `pushUser`)
  but have no peer tools of their own.
- A mirrored external CLI session (ADR 0012) isn't in the registry, so it can't be
  a target.
- Prompt injection is the real risk: text a session reads (a web page, a file) could
  instruct it to message a sibling. Mitigations: Ask mode, plan-mode refusal,
  rate limit, audit, header, target's own gate. Not a hard barrier in Auto mode.
- No app UI yet. A peer-origin turn shows as an ordinary user bubble with the
  header text; the tool call appears in the collapsed tool run (proposal 26).
- No ask-and-wait tool by design (deadlock-prone on mutual asks).
- Cross-project reach and a user-managed link list were deliberately left out.
