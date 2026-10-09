# M7 spike — SDK plan mode over streaming input

**Question (proposal 25):** can the daemon switch a live Agent SDK session into
plan mode, receive the plan through `canUseTool`, and approve/reject it?

**Script:** `vibe-daemon/src/spike-plan-mode.ts [allow|deny]` — throwaway temp-dir
cwd, SDK 0.3.169, real Claude (a few cents). Run 2026-10-06.

## Results

| # | Question | Result |
|---|----------|--------|
| a | `Query.setPermissionMode('plan')` mid-session with a streaming-input query | **Works.** The next turn's `system/init` reports `permissionMode: plan`. |
| b | ExitPlanMode reaches `canUseTool` | **Yes**, with `input = {plan, planFilePath}`. In plan mode the model first writes its plan to `~/.claude/plans/<name>.md` (that Write does **not** go through `canUseTool`), then calls ExitPlanMode. |
| c | Allowing it leaves plan mode | **Yes, by itself.** Returning `{behavior:'allow', updatedInput}` made the SDK leave plan mode; the next `Write` reached `canUseTool` and succeeded, and the following `init` reported `permissionMode: default`. No `updatedPermissions` needed. The daemon still calls `setPermissionMode` to land in the user's chosen mode. |
| d | Denying with a message keeps it planning | **Yes.** The deny `message` came back as the tool result ("Add a section on error handling first."); the model edited its plan file and called ExitPlanMode again. The spike's canned deny repeats forever by design — the model eventually asked a question instead of looping. |

## Consequences for the design

- ExitPlanMode must be special-cased before the auto-allow gate: with auto-allow on
  it would be approved instantly (found by reading `canUseTool` → `gate.request`).
- The deny message is the revision channel — the "Keep planning" feedback field
  maps straight onto it.
- The plan file path is outside the project root; the daemon never reads it — the
  plan text arrives in `input.plan`.
