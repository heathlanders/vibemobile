// Proposal 27 spike — prove: a user message pushed into the SDK input stream
// WHILE a turn is running is accepted, and find out how it is delivered (folded
// into the running turn vs. queued as its own turn) and how many `result`
// messages come back. Decides how the client tracks `busy`.
//
// Re-run: pnpm tsx src/spike-midturn.ts

import { query } from "@anthropic-ai/claude-agent-sdk";

const queue: any[] = [];
let wake: (() => void) | null = null;
const push = (text: string) => {
  queue.push({ type: "user", message: { role: "user", content: text }, parent_tool_use_id: null });
  wake?.();
  wake = null;
};
async function* input() {
  while (true) {
    while (queue.length) yield queue.shift();
    await new Promise<void>((res) => (wake = res));
  }
}

const t0 = Date.now();
const at = () => `+${((Date.now() - t0) / 1000).toFixed(1)}s`;

push("Run `sleep 12` with the Bash tool, then reply with exactly: FIRST-DONE");
setTimeout(() => {
  console.log(`[spike] ${at()} pushing 2nd message mid-turn`);
  push("Also, when you reply, end with the word SECOND-SEEN.");
}, 5000);

const q = query({
  prompt: input(),
  options: { cwd: "/tmp", permissionMode: "bypassPermissions", allowDangerouslySkipPermissions: true, maxTurns: 6 },
});

let results = 0;
for await (const msg of q) {
  if (msg.type === "assistant") {
    for (const b of (msg as any).message.content) {
      if (b.type === "text") console.log(`[spike] ${at()} assistant: ${JSON.stringify(b.text)}`);
      if (b.type === "tool_use") console.log(`[spike] ${at()} tool_use ${b.name}`);
    }
  } else if (msg.type === "user") {
    console.log(`[spike] ${at()} user-echo`);
  } else if (msg.type === "result") {
    results++;
    console.log(`[spike] ${at()} RESULT #${results} subtype=${(msg as any).subtype}`);
    if (results >= 2) break;
    // One result might cover both messages; give the stream a moment, then stop.
    setTimeout(() => {
      console.log(`[spike] ${at()} only ${results} result(s) after grace period → exiting`);
      process.exit(0);
    }, 20000);
  }
}
console.log(`[spike] ${at()} done, results=${results}`);
process.exit(0);
