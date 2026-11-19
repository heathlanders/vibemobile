// Spike (gap analysis: thinking blocks) — what does the REAL SDK stream when
// thinking is requested as {type:'adaptive', display:'summarized'}?
//  (a) stream_event deltas: thinking_delta? signature_delta?
//  (b) final assistant message: a content block of type 'thinking' with text?
//  (c) is a thinking block present with display omitted / by default?
// Usage: tsx src/spike-thinking.ts [summarized|omitted|default]   (temp cwd, few cents)

import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { query } from "@anthropic-ai/claude-agent-sdk";

const mode = process.argv[2] ?? "summarized";
const cwd = mkdtempSync(join(tmpdir(), "spike-think-"));
const [kind, disp] = mode.split(":"); // e.g. enabled:summarized | adaptive:summarized | default
const thinking = kind === "default" ? undefined : kind === "enabled" ? { type: "enabled", budgetTokens: 4000, display: disp ?? "summarized" } : { type: "adaptive", display: disp ?? "summarized" };
console.log(`[spike] thinking=${JSON.stringify(thinking)} cwd=${cwd}`);

const q = query({
  prompt: "Think hard step by step: how many distinct ways can 8 non-attacking rooks be placed on an 8x8 board with the top-left 3x3 squares forbidden? Show the method briefly and give the number.",
  options: { cwd, includePartialMessages: true, permissionMode: "default", maxTurns: 1, thinking, canUseTool: async (_n: string, i: any) => ({ behavior: "allow", updatedInput: i }) } as any,
});
const seen: Record<string, number> = {};
let thinkText = "";
for await (const msg of q as AsyncGenerator<any>) {
  if (msg.type === "system" && msg.subtype === "init") console.log(`[init] model=${msg.model}`);
  if (msg.type === "stream_event") {
    const ev = msg.event;
    const key = `stream:${ev.type}${ev.delta?.type ? "/" + ev.delta.type : ""}${ev.content_block?.type ? "@" + ev.content_block.type : ""}`;
    seen[key] = (seen[key] ?? 0) + 1;
    if (ev.delta?.type === "thinking_delta") thinkText += ev.delta.thinking ?? "";
  } else if (msg.type === "assistant") {
    for (const b of msg.message?.content ?? []) {
      console.log(`[assistant block] type=${b.type} ${b.type === "thinking" ? `thinking=${JSON.stringify((b.thinking ?? "").slice(0, 160))} sig=${!!b.signature}` : JSON.stringify(b).slice(0, 120)}`);
    }
  } else if (msg.type === "result") {
    console.log(`[result] ${msg.subtype} cost=${msg.total_cost_usd}`);
  }
}
console.log("[stream event counts]", JSON.stringify(seen, null, 1));
console.log(`[accumulated thinking_delta chars] ${thinkText.length}: ${JSON.stringify(thinkText.slice(0, 200))}`);
