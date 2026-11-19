// Spike (proposal 43) — MCP servers over the Agent SDK.
//  (a) Query.mcpServerStatus(): which fields, and does `config` carry secrets?
//  (b) a broken stdio server -> status failed + error; reconnect / toggle behaviour
//  (c) claude.ai connectors -> needs-auth (cannot be authorized non-interactively)
// Usage: tsx src/spike-mcp.ts   (temp cwd with a deliberately broken .mcp.json; no model call)
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { query } from "@anthropic-ai/claude-agent-sdk";

const cwd = mkdtempSync(join(tmpdir(), "spike-mcp-"));
const SECRET = "sk-spike-TOPSECRET-999";
writeFileSync(join(cwd, ".mcp.json"), JSON.stringify({ mcpServers: { brokentool: { command: "/nonexistent/mcp-server", args: [`--key=${SECRET}`], env: { API_KEY: SECRET } } } }));
async function* input() { await new Promise(() => {}); }
const q: any = query({ prompt: input(), options: { cwd, permissionMode: "default", canUseTool: async (_n: string, i: any) => ({ behavior: "allow", updatedInput: i }) } as any });
await q.initializationResult();
await new Promise((r) => setTimeout(r, 2500)); // give the CLI a moment to try the servers
const st = async () => (await q.mcpServerStatus()).map((s: any) => `${s.name}=${s.status}`).join(", ");
const raw = await q.mcpServerStatus();
console.log("(a) keys:", Object.keys(raw[0]).join(","), "| 'config' carries the secret:", JSON.stringify(raw).includes(SECRET));
console.log("(b)", await st());
const t = async (label: string, f: () => Promise<unknown>) => { try { await f(); console.log(`    ${label}: resolved`); } catch (e: any) { console.log(`    ${label}: REJECTED (${String(e?.message).slice(0, 60)})`); } console.log("    ->", await st()); };
await t("reconnect brokentool", () => q.reconnectMcpServer("brokentool"));
await t("disable brokentool", () => q.toggleMcpServer("brokentool", false));
await t("enable brokentool", () => q.toggleMcpServer("brokentool", true));
process.exit(0);
