// Proposal 16 spike — prove: the Agent SDK accepts an IMAGE content block in the
// streaming input (not just text). Sends one user turn = [text, image] where the
// image is a solid-red PNG, then checks the assistant names the colour red.
// Decides the wire/server design in docs/proposals/16-image-input.md.
//
// Re-run: pnpm tsx src/spike-image.ts [/path/to/image.png]   (default /tmp/red.png)

import { readFileSync } from "node:fs";
import { query } from "@anthropic-ai/claude-agent-sdk";

const imgPath = process.argv[2] ?? "/tmp/red.png";
const data = readFileSync(imgPath).toString("base64");
const cwd = "/home/user/my-project";

console.log(`[spike] image: ${imgPath}  b64 bytes: ${data.length}`);

// Streaming input, same shape as ClaudeSession.input() (src/claude.ts:114) — but
// content is an ARRAY of blocks instead of a bare string. This is the open
// question: does the SDK forward an image block to the model?
async function* input() {
  yield {
    type: "user",
    message: {
      role: "user",
      content: [
        { type: "text", text: "What single colour fills this image? Reply with one word. Do not use any tools." },
        { type: "image", source: { type: "base64", media_type: "image/png", data } },
      ],
    },
    parent_tool_use_id: null,
  };
}

const q = query({ prompt: input(), options: { cwd, maxTurns: 1 } });

let answer = "";
for await (const msg of q) {
  if (msg.type === "system" && (msg as any).subtype === "init") {
    console.log(`[event] init  model=${(msg as any).model}`);
  } else if (msg.type === "assistant") {
    const text = (msg as any).message?.content
      ?.filter((b: any) => b.type === "text")
      .map((b: any) => b.text)
      .join("");
    if (text) {
      answer += text;
      console.log(`[event] assistant: ${text}`);
    }
  } else if (msg.type === "result") {
    console.log(`[event] result subtype=${(msg as any).subtype} cost=$${(msg as any).total_cost_usd ?? 0}`);
  } else {
    console.log(`[event] ${msg.type}${(msg as any).subtype ? "/" + (msg as any).subtype : ""}`);
  }
}

const sawRed = /red/i.test(answer);
console.log(`[spike] DONE. saw "red": ${sawRed ? "YES — SDK forwards image blocks" : "NO — check format"}`);
process.exit(sawRed ? 0 : 1);
