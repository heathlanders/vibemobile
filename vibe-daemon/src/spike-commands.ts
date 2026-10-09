// Spike (proposal 41) — slash commands / skills over the Agent SDK.
//  (a) does Query.supportedCommands() answer BEFORE any user message (the SDK only emits `init`
//      on the first message)?  (b) does it list a project command + mark Claude's own `builtin`?
//  (c) does a streamed "/name args" message run the command?
// Usage: tsx src/spike-commands.ts   (temp cwd with .claude/commands/hello.md, a few cents)
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { query } from "@anthropic-ai/claude-agent-sdk";

const cwd = mkdtempSync(join(tmpdir(), "spike-cmds-"));
mkdirSync(join(cwd, ".claude", "commands"), { recursive: true });
writeFileSync(join(cwd, ".claude", "commands", "hello.md"), "---\ndescription: Say the magic marker\nargument-hint: <word>\n---\nReply with exactly this text and nothing else: MAGIC-MARKER-42 $ARGUMENTS\n");
const queue: any[] = []; let wake: (() => void) | null = null; let closed = false;
const push = (t: string) => { queue.push({ type: "user", message: { role: "user", content: t }, parent_tool_use_id: null }); wake?.(); wake = null; };
async function* input() { while (!closed) { while (queue.length) yield queue.shift(); if (closed) break; await new Promise<void>((r) => (wake = r)); } }
const q: any = query({ prompt: input(), options: { cwd, permissionMode: "default", canUseTool: async (_n: string, i: any) => ({ behavior: "allow", updatedInput: i }) } as any });

const t0 = Date.now();
const cmds = await q.supportedCommands(); // no message sent yet
const builtins = cmds.filter((c: any) => c.builtin);
const ctx = await q.getContextUsage({ detail: "summary" });
const skillNames = new Set<string>((ctx.skills?.skillFrontmatter ?? []).map((s: any) => s.name));
const builtinSkills = builtins.filter((c: any) => skillNames.has(c.name)).map((c: any) => c.name);
const terminalBuiltins = builtins.filter((c: any) => !skillNames.has(c.name)).map((c: any) => c.name);
console.log(`(b2) of the ${builtins.length} builtin-flagged rows, ${builtinSkills.length} are SKILLS (offered): ${builtinSkills.join(", ")}`);
console.log(`(b3) ${terminalBuiltins.length} are terminal/UX built-ins (withheld): ${terminalBuiltins.slice(0, 8).join(", ")}, …`);
console.log(`(a) supportedCommands() before any input: ${cmds.length} commands in ${Date.now() - t0} ms`);
console.log(`(b) builtin-flagged: ${builtins.length} (e.g. ${builtins.slice(0, 4).map((c: any) => c.name).join(", ")}); hello listed: ${JSON.stringify(cmds.find((c: any) => c.name === "hello"))}`);

push("/hello banana");
let reply = "";
for await (const m of q as AsyncGenerator<any>) {
  if (m.type === "assistant") for (const b of m.message?.content ?? []) if (b.type === "text") reply += b.text;
  if (m.type === "result") break;
}
console.log(`(c) '/hello banana' ->`, JSON.stringify(reply.slice(0, 80)));
closed = true; wake?.();
process.exit(0);
