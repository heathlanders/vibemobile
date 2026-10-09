# M0 Spike 1 — Agent SDK auth & event stream

**Status:** ✅ Passed (2026-06-08)
**Code:** `vibe-daemon/src/spike-claude.ts`
**Run:** `cd vibe-daemon && npm run spike:claude [cwd]`

## Risk being killed

`PLAN.md §7`: does `@anthropic-ai/claude-agent-sdk` use the existing `claude`
CLI login, or does it need a separate `ANTHROPIC_API_KEY`? Changes the cost
model and pairing/setup story.

## What the spike does

Calls `query()` with `maxTurns: 1` against a project cwd, no API key in env,
and prints every streamed message type plus the session id.

## Result

```
[spike] ANTHROPIC_API_KEY set: no
[event] init  session_id=68cf8e1e-… model=claude-opus-4-8[1m]
[event] assistant: … Model: Claude Opus 4.8 (1M context). Working dir: my-project.
[event] result subtype=success cost=$0.229255
```

## Findings

- **No API key needed** — SDK authenticates via the existing `claude` CLI login.
  This is the answer to the §7 open question.
- **Event shape** for the wire protocol: filter on `msg.type`:
  - `system` / subtype `init` → `session_id`, `model` (capture for resume).
  - `assistant` → `message.content[]`, take `type === "text"` blocks.
  - `result` → `subtype` (`success`), `total_cost_usd`.
- **Hooks fire inside the SDK session** — the target project's own hooks run
  (observed: target project's session-start hook loaded). The daemon must be
  aware sessions inherit per-project hook behavior.
- One turn cost ~$0.23.

## Follow-ups

- Confirm `session_id` resume works (`options.resume`) — needed for M3.
- Map permission/tool-use events (`tool_use`, permission requests) for the
  approve/deny UI — not exercised here (`maxTurns: 1`, no tools).
