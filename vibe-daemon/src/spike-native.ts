// Native engine spike (ADR 0008, M6 — the gate for the native build). Proves the
// riskiest unknown live: does a real non-Claude model (OpenAI) run its OWN native
// tool loop through the Vercel AI SDK — chat + a forced tool round-trip — and does
// the fullStream part shape match what native.ts switches on?
//
// Run (needs a real key):
//   OPENAI_API_KEY=sk-… npm run spike:native -- <model-id>
//   e.g. … npm run spike:native -- gpt-4o
//
// PASS = we see text streaming + at least one tool-call/tool-result + a clean finish
// with usage. FAIL (no tool call, or a part shape native.ts doesn't handle) = adjust
// the engine's switch to the printed part types before shipping that provider.

import { streamText, stepCountIs, tool } from "ai";
import { createOpenAI } from "@ai-sdk/openai";
import { z } from "zod";

const model = process.argv[2] ?? "gpt-4o";
console.log(`[spike] OPENAI_API_KEY set: ${process.env.OPENAI_API_KEY ? "yes" : "no"}`);
console.log(`[spike] model=${model}`);

const openai = createOpenAI({ apiKey: process.env.OPENAI_API_KEY ?? "" });

let sawToolCall = false;
let sawToolResult = false;
let finished = false;

const result = streamText({
  model: openai(model),
  prompt: "Use the list_dir tool to list the current directory, then reply with the number of entries.",
  stopWhen: stepCountIs(6),
  tools: {
    list_dir: tool({
      description: "List entries of a directory.",
      inputSchema: z.object({ path: z.string().describe("Directory path") }),
      execute: async ({ path }) => {
        sawToolCall = true;
        console.log(`[event] tool execute: list_dir(${path})`);
        return "a.txt\nb.txt\nsrc/"; // canned — the spike proves the LOOP, not the fs
      },
    }),
  },
});

for await (const part of result.fullStream as AsyncIterable<any>) {
  switch (part.type) {
    case "text-delta":
      process.stdout.write(part.text ?? "");
      break;
    case "tool-call":
      console.log(`\n[event] tool-call name=${part.toolName} input=${JSON.stringify(part.input)}`);
      break;
    case "tool-result":
      sawToolResult = true;
      console.log(`[event] tool-result=${JSON.stringify(part.output)}`);
      break;
    case "finish":
      finished = true;
      console.log(`\n[event] finish reason=${part.finishReason} usage=${JSON.stringify(part.totalUsage)}`);
      break;
    case "error":
      console.log(`\n[event] error=${String(part.error)}`);
      break;
    default:
      console.log(`[event] ${part.type}`);
  }
}

const pass = sawToolCall && sawToolResult && finished;
console.log(`\n[spike] tool_call=${sawToolCall} tool_result=${sawToolResult} finish=${finished}`);
console.log(`[spike] ${pass ? "PASS — native chat + tool loop work for this model" : "FAIL — see events above"}`);
process.exit(pass ? 0 : 1);
