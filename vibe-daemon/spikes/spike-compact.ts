// Spike — context meter + compaction over the Agent SDK (gap analysis).
//  (a) Query.getContextUsage({detail:'summary'}) after a turn: shape + cost of the call
//  (b) does pushing "/compact" as a streamed user message compact? what messages come back?
//  (c) context usage before/after, and the compact_boundary metadata
// Usage: tsx src/spike-compact.ts   (temp cwd, a few cents)
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { query } from "@anthropic-ai/claude-agent-sdk";

const cwd = mkdtempSync(join(tmpdir(), "spike-compact-"));
const queue: any[] = []; let wake: (() => void) | null = null; let closed = false;
const push = (t: string) => { queue.push({ type: "user", message: { role: "user", content: t }, parent_tool_use_id: null }); wake?.(); wake = null; };
async function* input() { while (!closed) { while (queue.length) yield queue.shift(); if (closed) break; await new Promise<void>((r) => (wake = r)); } }
const q: any = query({ prompt: input(), options: { cwd, permissionMode: "default", canUseTool: async (_n: string, i: any) => ({ behavior: "allow", updatedInput: i }) } as any });
const it = q[Symbol.asyncIterator]();
const ctx = async (label: string, detail: "summary" | "full" = "summary") => {
  const t0 = Date.now();
  const u = await q.getContextUsage({ detail });
  console.log(`[ctx ${label}/${detail}] ${Date.now() - t0}ms total=${u.total_tokens} max=${u.raw_max_tokens} pct=${u.percentage} model=${u.model} cats=${u.categories.map((c: any) => `${c.name}:${c.tokens}`).join(",")}`);
  return u;
};
let turn = 0;
const kinds: Record<string, number> = {};
push("Write two short paragraphs about the history of the rook in chess.");
setTimeout(() => { console.log("TIMEOUT"); process.exit(2); }, 150000).unref();
for (;;) {
  const { value: m, done } = await it.next();
  if (done) break;
  const k = m.type + (m.subtype ? "/" + m.subtype : "");
  kinds[k] = (kinds[k] ?? 0) + 1;
  if (m.type === "system" && m.subtype === "compact_boundary") console.log("[compact_boundary]", JSON.stringify(m.compact_metadata));
  if (m.type === "system" && m.subtype === "local_command_output") console.log("[local_command_output]", JSON.stringify(m).slice(0, 200));
  if (m.type === "user" && typeof m.message?.content === "string") console.log("[user string]", m.message.content.slice(0, 120));
  if (m.type === "result") {
    turn++;
    console.log(`[result ${turn}] ${m.subtype} ${JSON.stringify(m.result ?? "").slice(0, 80)}`);
    if (turn === 1) { await ctx("after turn 1"); await ctx("after turn 1", "full"); push("Now two more paragraphs about the history of the knight."); }
    else if (turn === 2) { await ctx("before compact"); console.log("[push] /compact"); push("/compact"); }
    else { await ctx("after compact"); closed = true; wake?.(); break; }
  }
}
console.log("[message kinds seen]", JSON.stringify(kinds));
process.exit(0);
