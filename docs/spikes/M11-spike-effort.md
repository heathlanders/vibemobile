# M11 spike — reasoning effort over the Agent SDK

**Question (gap analysis):** can the daemon set a session's reasoning effort, at start and
live, and does it change anything observable?

**Script:** `vibe-daemon/src/spike-effort.ts [start low|start max|live low]` — throwaway
temp-dir cwd, SDK 0.3.291, model `claude-sonnet-5-5`, adaptive summarized thinking, real
Claude (a few cents per run). Run 2026-10-07 on a hard counting question.

## Results

| # | Question | Result |
|---|----------|--------|
| a | `effort` start option | **Works and is measurable.** `low`: 173 output tokens, 241 thinking chars, 6.1 s. `max`: 490 output tokens, 614 thinking chars, 7.3 s. |
| b | `Query.applyFlagSettings({effortLevel})` between turns | **Accepted** (`resolved`); the next turn did less work. (The re-asked question is partly answered from context, so the size of that effect is confounded — acceptance is the finding.) |
| c | `null` | Per the SDK docs `effortLevel: null` returns to the model's default. |
| d | Unsupported models | The SDK silently downgrades (`max` runs as `high` where unsupported) — the daemon does not second-guess it. |

Through `ClaudeSession` (real SDK): set `low` live → persisted → a **fresh session object**
(simulating a daemon restart) starts with `low` → set `max` → noticeably more reasoning
(500 vs ~200 thinking chars).

## Consequences

- Persist the level (`sessions.effort`) and pass it as the `effort` start option, so a resume,
  reap or restart keeps it; change it live with `applyFlagSettings`.
- Whitelist the five levels in the daemon (`low|medium|high|xhigh|max`) — a raw string never
  reaches the SDK.
