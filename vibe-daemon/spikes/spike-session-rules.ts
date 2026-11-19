// Spike (ADR 0026) — can the daemon inject rules into EVERY session's system prompt
// without breaking the project's own CLAUDE.md?
//  (a) default options (what ClaudeSession passes today): is the project's CLAUDE.md loaded?
//  (b) systemPrompt {type:'preset', preset:'claude_code', append}: is the appended text obeyed,
//      and is CLAUDE.md STILL loaded alongside it?
// Usage: tsx src/spike-session-rules.ts [default|append]   (temp cwd, a few cents)

import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { query } from "@anthropic-ai/claude-agent-sdk";

const mode = process.argv[2] ?? "append";
const cwd = mkdtempSync(join(tmpdir(), "spike-rules-"));
writeFileSync(join(cwd, "CLAUDE.md"), "# Project rules\nWhenever you answer, include the exact marker PROJECT-MARKER-7 somewhere in the reply.\n");
const options: any = { cwd, permissionMode: "default", maxTurns: 1, canUseTool: async (_n: string, i: any) => ({ behavior: "allow", updatedInput: i }) };
if (mode === "append") {
  options.systemPrompt = { type: "preset", preset: "claude_code", append: "# Session rules\nWhenever you answer, include the exact marker DAEMON-MARKER-9 somewhere in the reply." };
}
console.log(`[spike] mode=${mode} cwd=${cwd}`);
let text = "";
for await (const m of query({ prompt: "Say hello in one short sentence.", options }) as AsyncGenerator<any>) {
  if (m.type === "assistant") for (const b of m.message?.content ?? []) if (b.type === "text") text += b.text;
}
console.log("[reply]", JSON.stringify(text));
console.log("PROJECT-MARKER-7 (CLAUDE.md loaded):", text.includes("PROJECT-MARKER-7"));
console.log("DAEMON-MARKER-9 (append obeyed):    ", text.includes("DAEMON-MARKER-9"));
