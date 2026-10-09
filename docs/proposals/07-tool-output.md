# Proposal 07 — Tool output rendering

## Why
The `tool_use` card shows tool name + input only; the result never renders. Feels
broken — you see Claude call `Read`/`Bash` but not what came back. Biggest
"unfinished" gap in the chat UI.

## Sketch
Daemon already receives tool results from the SDK stream. Emit a `tool_result`
frame keyed by `toolUseID`, persist alongside the call, and render it collapsed
under the matching tool chip (tap to expand). Truncate long output with a
"show more".

## Impact
- **Wire:** add `tool_result` frame `{ toolUseID, content, isError }`
  ([claude-ws.md](../protocols/claude-ws.md)).
- **Schema:** store result on the `messages` tool row (reuse `tool_json`) so replay
  on attach shows it.
- **Client:** match result → call by `toolUseID`; expandable section in `_Bubble`
  tool branch.

## Open
- Truncation threshold + raw-vs-pretty for JSON/diff output.
- Render `isError` results distinctly (error color).
