// Spike (proposal 25) — prove, against the REAL Agent SDK, how permission modes
// behave over streaming input:
//  (a) Query.setPermissionMode('plan') works mid-session
//  (b) ExitPlanMode reaches canUseTool with the plan text in `input`
//  (c) allowing it leaves plan mode (does a later Write get through?)
//  (d) denying with a message keeps the model planning
// Usage: tsx src/spike-plan-mode.ts [allow|deny]   (cwd is a throwaway temp dir)
// Spends a few cents of real Claude usage. Never run against a real project.

import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { query } from "@anthropic-ai/claude-agent-sdk";

const decision = (process.argv[2] ?? "allow") as "allow" | "deny";
const cwd = mkdtempSync(join(tmpdir(), "spike-plan-"));
console.log(`[spike] cwd=${cwd} exitPlanDecision=${decision}`);

const queue: any[] = [];
let wake: (() => void) | null = null;
let closed = false;
const push = (text: string) => {
  queue.push({ type: "user", message: { role: "user", content: text }, parent_tool_use_id: null });
  wake?.();
  wake = null;
};
async function* input() {
  while (!closed) {
    while (queue.length) yield queue.shift();
    if (closed) break;
    await new Promise<void>((r) => (wake = r));
  }
}

let exitPlanSeen = false;
const q = query({
  prompt: input(),
  options: {
    cwd,
    permissionMode: "default",
    maxTurns: 8,
    canUseTool: async (toolName: string, toolInput: Record<string, unknown>, opts: any) => {
      console.log(`[canUseTool] ${toolName} ${JSON.stringify(toolInput).slice(0, 160)}`);
      if (toolName === "ExitPlanMode") {
        exitPlanSeen = true;
        console.log(`[ExitPlanMode] input keys: ${Object.keys(toolInput).join(",")}`);
        if (decision === "deny") return { behavior: "deny", message: "Add a section on error handling first." };
        return { behavior: "allow", updatedInput: toolInput };
      }
      return { behavior: "allow", updatedInput: toolInput };
    },
  } as any,
});

(async () => {
  // (a) switch to plan mode only after the session is live
  push("Say 'ready' and nothing else. Do not use tools.");
})();

let turn = 0;
for await (const msg of q as AsyncGenerator<any>) {
  if (msg.type === "system" && msg.subtype === "init") console.log(`[init] permissionMode=${msg.permissionMode}`);
  else if (msg.type === "assistant") {
    for (const b of msg.message?.content ?? []) {
      if (b.type === "text" && b.text) console.log(`[assistant] ${b.text.slice(0, 200)}`);
      if (b.type === "tool_use") console.log(`[tool_use] ${b.name}`);
    }
  } else if (msg.type === "user") {
    for (const b of msg.message?.content ?? []) {
      if (b.type === "tool_result") console.log(`[tool_result] ${JSON.stringify(b.content).slice(0, 200)}`);
    }
  } else if (msg.type === "result") {
    turn++;
    console.log(`[result] turn=${turn} subtype=${msg.subtype}`);
    if (turn === 1) {
      await (q as any).setPermissionMode("plan");
      console.log("[spike] setPermissionMode('plan') OK");
      push("Create a file hello.txt containing 'hi'. You are in plan mode: plan it, then call ExitPlanMode.");
    } else if (turn === 2) {
      console.log(`[spike] exitPlanSeen=${exitPlanSeen}`);
      if (decision === "allow") push("Now create hello.txt as planned.");
      else {
        closed = true;
        wake?.();
      }
    } else {
      closed = true;
      wake?.();
    }
  }
}
console.log(`[spike] DONE exitPlanSeen=${exitPlanSeen}`);
