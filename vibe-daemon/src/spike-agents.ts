// Spike (token-saving, post: andreagrandi.it subagents) — do user-level subagents in
// ~/.claude/agents/*.md load in a session configured like claude.ts, and does delegating
// to one run on the subagent's model?
// Usage: tsx src/spike-agents.ts    (cwd is a throwaway temp dir; spends a few cents)

import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { query } from "@anthropic-ai/claude-agent-sdk";

const cwd = mkdtempSync(join(tmpdir(), "spike-agents-"));
writeFileSync(join(cwd, "a.txt"), "apple\n");
writeFileSync(join(cwd, "b.txt"), "banana split\n");
console.log(`[spike] cwd=${cwd}`);

const q = query({
  prompt: "Use the scoper subagent (Agent tool, subagent_type 'scoper') to find which file here contains the word banana. Then tell me the filename.",
  options: { cwd, model: "sonnet", permissionMode: "acceptEdits", maxTurns: 8 },
});
for await (const m of q as AsyncIterable<any>) {
  if (m.type === "system" && m.subtype === "init") console.log("[init] agents:", m.agents, "model:", m.model);
  if (m.type === "assistant") {
    for (const b of m.message?.content ?? []) {
      if (b.type === "tool_use") console.log(`[tool_use]${m.parent_tool_use_id ? " (in subagent)" : ""}`, b.name, JSON.stringify(b.input).slice(0, 140));
      if (b.type === "text" && !m.parent_tool_use_id) console.log("[assistant]", b.text.slice(0, 200));
    }
    console.log("[model]", m.message?.model, m.parent_tool_use_id ? "(subagent)" : "(main)");
  }
  if (m.type === "result") {
    console.log("[result]", m.subtype, "cost", m.total_cost_usd);
    for (const [k, u] of Object.entries(m.modelUsage ?? {})) console.log("  usage", k, "out", (u as any).outputTokens, "$", (u as any).costUSD);
  }
}
