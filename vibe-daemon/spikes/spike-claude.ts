// M0 spike 1 — prove: Agent SDK drives a Claude session, streams events,
// and (critically) authenticates via the existing `claude` CLI login WITHOUT
// an ANTHROPIC_API_KEY. Prints every message type + the session id.

import { query } from "@anthropic-ai/claude-agent-sdk";

const cwd = process.argv[2] ?? "/home/user/my-project";

console.log(`[spike] ANTHROPIC_API_KEY set: ${process.env.ANTHROPIC_API_KEY ? "yes" : "no"}`);
console.log(`[spike] cwd: ${cwd}`);

const q = query({
  prompt: "Reply in one short sentence: which model are you, and what is the name of the current working directory? Do not use any tools.",
  options: { cwd, maxTurns: 1 },
});

let sessionId: string | undefined;

for await (const msg of q) {
  if (msg.type === "system" && (msg as any).subtype === "init") {
    sessionId = (msg as any).session_id;
    console.log(`[event] init  session_id=${sessionId} model=${(msg as any).model}`);
  } else if (msg.type === "assistant") {
    const text = (msg as any).message?.content
      ?.filter((b: any) => b.type === "text")
      .map((b: any) => b.text)
      .join("");
    if (text) console.log(`[event] assistant: ${text}`);
  } else if (msg.type === "result") {
    console.log(`[event] result subtype=${(msg as any).subtype} cost=$${(msg as any).total_cost_usd ?? 0}`);
  } else {
    console.log(`[event] ${msg.type}${(msg as any).subtype ? "/" + (msg as any).subtype : ""}`);
  }
}

console.log(`[spike] DONE. session_id=${sessionId}`);
