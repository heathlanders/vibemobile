// Spike — effort levels over the Agent SDK (gap analysis: effort control).
//  (a) does the `effort` start option change anything observable (thinking length / cost / time)?
//  (b) does Query.applyFlagSettings({effortLevel}) work live between turns, and what is the
//      model's reported effort afterwards (hooks expose it; here we compare behaviour)?
// Usage: tsx src/spike-effort.ts [start low|start max|live]   (temp cwd, a few cents)
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { query } from "@anthropic-ai/claude-agent-sdk";

const [mode, level] = [process.argv[2] ?? "start", process.argv[3] ?? "low"];
const cwd = mkdtempSync(join(tmpdir(), "spike-effort-"));
const PROMPT = "How many distinct ways can 8 non-attacking rooks be placed on an 8x8 board with the top-left 3x3 squares forbidden? Give just the number.";
const queue: any[] = []; let wake: (() => void) | null = null; let closed = false;
const push = (t: string) => { queue.push({ type: "user", message: { role: "user", content: t }, parent_tool_use_id: null }); wake?.(); wake = null; };
async function* input() { while (!closed) { while (queue.length) yield queue.shift(); if (closed) break; await new Promise<void>((r) => (wake = r)); } }
const options: any = { cwd, includePartialMessages: true, thinking: { type: "adaptive", display: "summarized" }, permissionMode: "default", canUseTool: async (_n: string, i: any) => ({ behavior: "allow", updatedInput: i }) };
if (mode === "start") options.effort = level;
const q: any = query({ prompt: input(), options });
const it = q[Symbol.asyncIterator]();
let turn = 0, thinkChars = 0, t0 = Date.now();
push(PROMPT);
for (;;) {
  const { value: m, done } = await it.next();
  if (done) break;
  if (m.type === "stream_event" && m.event?.delta?.type === "thinking_delta") thinkChars += m.event.delta.thinking?.length ?? 0;
  if (m.type === "result") {
    turn++;
    console.log(`[turn ${turn}] effort=${mode === "live" ? (turn === 1 ? "default" : level) : level} thinkingChars=${thinkChars} cost=$${m.total_cost_usd?.toFixed(4)} ms=${Date.now() - t0} out_tokens=${m.usage?.output_tokens}`);
    thinkChars = 0; t0 = Date.now();
    if (mode === "live" && turn === 1) {
      try { await q.applyFlagSettings({ effortLevel: level }); console.log(`[live] applyFlagSettings({effortLevel:'${level}'}) resolved`); } catch (e: any) { console.log("[live] applyFlagSettings threw:", e?.message); }
      push(PROMPT + " (same question, answer again)");
    } else { closed = true; wake?.(); break; }
  }
}
process.exit(0);
