// Gateway spike (ADR 0007, gate for the model-agnostic work). Proves the ONE
// riskiest unknown: does the Agent SDK's bundled `claude` CLI honor base-URL mode
// (ANTHROPIC_BASE_URL + ANTHROPIC_AUTH_TOKEN via options.env) AND keep the full
// tool loop when routed through a local Anthropic-compat gateway at a NON-Claude
// upstream model?
//
// Run (needs a gateway on 127.0.0.1:4000 translating to some upstream model):
//   VIBE_GATEWAY_URL=http://127.0.0.1:4000 VIBE_GATEWAY_TOKEN=<tok> \
//   npm run spike:gateway -- <cwd> <model-id>
//
// PASS = the loop completes: init → assistant(tool_use) → user(tool_result) →
// result success, through the given non-Claude model. That tool round-trip IS the
// tool-use-fidelity check for translated models. FAIL (CLI ignores base URL / no
// tool_use) = stop; fall back to claude-code-router. See
// docs/spikes/M5-spike-gateway-model-swap.md.

import { query } from "@anthropic-ai/claude-agent-sdk";
import { gatewayEnv } from "./gateway.js";

const cwd = process.argv[2] ?? process.cwd();
const model = process.argv[3]; // e.g. "gpt-4o" (as named in the gateway config)

const env = gatewayEnv();
console.log(`[spike] VIBE_GATEWAY_URL=${process.env.VIBE_GATEWAY_URL ?? "(unset!)"}`);
console.log(`[spike] model=${model ?? "(default)"}  cwd=${cwd}`);
if (!env) console.log("[spike] WARNING: no gateway env — set VIBE_GATEWAY_URL to actually route.");

// A prompt that forces at least one tool call so we exercise the whole loop.
const q = query({
  prompt: "Use a tool to list the files in the current directory, then reply with the count. Do not guess.",
  options: {
    cwd,
    model: model ?? undefined,
    env,
    permissionMode: "bypassPermissions", // spike only — the real daemon keeps the gate
    includePartialMessages: false,
  },
});

let sawToolUse = false;
let sawToolResult = false;
let ok = false;

for await (const msg of q) {
  const m = msg as any;
  if (m.type === "system" && m.subtype === "init") {
    console.log(`[event] init  session_id=${m.session_id} model=${m.model}`);
  } else if (m.type === "assistant") {
    for (const b of m.message?.content ?? []) {
      if (b.type === "text" && b.text) console.log(`[event] assistant: ${b.text}`);
      if (b.type === "tool_use") {
        sawToolUse = true;
        console.log(`[event] tool_use name=${b.name} input=${JSON.stringify(b.input)}`);
      }
    }
  } else if (m.type === "user") {
    for (const b of m.message?.content ?? []) {
      if (b.type === "tool_result") {
        sawToolResult = true;
        console.log(`[event] tool_result (is_error=${!!b.is_error})`);
      }
    }
  } else if (m.type === "result") {
    ok = m.subtype === "success";
    console.log(`[event] result subtype=${m.subtype} cost=$${m.total_cost_usd ?? 0}`);
  } else {
    console.log(`[event] ${m.type}${m.subtype ? "/" + m.subtype : ""}`);
  }
}

const pass = sawToolUse && sawToolResult && ok;
console.log(`\n[spike] tool_use=${sawToolUse} tool_result=${sawToolResult} result_ok=${ok}`);
console.log(`[spike] ${pass ? "PASS — gateway routing + tool loop work through this model" : "FAIL — see notes above"}`);
process.exit(pass ? 0 : 1);
