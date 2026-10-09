// D18 spike (security.md #7): which Read calls reach canUseTool in permissionMode
// 'default'? Throwaway temp dirs, real Claude (haiku, ~1 cent).
// Re-run: npx tsx src/spike-file-scope.ts
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { query } from "@anthropic-ai/claude-agent-sdk";

const root = mkdtempSync(join(tmpdir(), "scope-spike-"));
const proj = join(root, "proj");
const outside = join(root, "outside");
mkdirSync(proj);
mkdirSync(outside);
writeFileSync(join(proj, "in.txt"), "inside-ok\n");
writeFileSync(join(outside, "out.txt"), "outside-ok\n");

const calls: [string, unknown][] = [];
const q = query({
  prompt: `Use the Read tool on ${join(proj, "in.txt")} and then on ${join(outside, "out.txt")}, then reply with both contents.`,
  options: {
    cwd: proj,
    model: "haiku",
    permissionMode: "default",
    persistSession: false,
    settingSources: [],
    canUseTool: async (tool: string, input: Record<string, unknown>) => {
      calls.push([tool, input.file_path]);
      return { behavior: "allow", updatedInput: input };
    },
  },
});
for await (const m of q) if (m.type === "result") console.log("result:", String((m as any).result).slice(0, 120));
console.log("canUseTool calls:", JSON.stringify(calls));
rmSync(root, { recursive: true });
