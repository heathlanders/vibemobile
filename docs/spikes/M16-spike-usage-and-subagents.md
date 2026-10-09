# M16 — Spike: SDK usage is cumulative; user subagents load and run on their own model

Real Agent SDK 0.3.291, throwaway temp dirs, a few cents of usage.

## 1. `modelUsage` / `total_cost_usd` are cumulative
- Two turns in one `query`: Sonnet output 35 → 71, total cost $0.0931 → $0.1063. `result.usage` is per-turn (35, 36).
- A `resume` in a **new process** continues the same counters (Sonnet out 6 → 11, cacheWrite 11120 → 22283, total $0.0479 → $0.0949).
- Consequence: record deltas against a persisted baseline, never an in-memory zero. See ADR 0017 amendment, `spend.ts`.

## 2. User subagents (`~/.claude/agents/*.md`)
`src/spike-agents.ts`: a session configured like `claude.ts` (no `settingSources`) lists `implementer`, `reviewer`, `scoper`, `shipper` in the `init` message. Asked to use `scoper`, the main Sonnet session called the `Agent` tool; the subagent's turns ran on `claude-haiku-4-5` (`parent_tool_use_id` set) and `modelUsage` shows both models separately (Haiku 357 out / $0.011, Sonnet 235 out / $0.104).
- Consequence: the post's technique needs **no VibeMobile code**; the agent files are enough, and the spend ledger already attributes cost per model.
- Delegation rules (when the main session should delegate) belong in the user's CLAUDE.md, not in the daemon.
