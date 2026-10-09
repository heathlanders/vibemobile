// MCP servers as the app sees them (proposal 43). Built from Query.mcpServerStatus().
//
// SECURITY: the SDK's status includes each server's `config` — for stdio servers that is the
// launch command, its args and its ENVIRONMENT (API keys live there), and for HTTP servers a
// URL that can embed tokens. None of it is ever forwarded. Only names, state, version, scope,
// a short error and the tool list leave the daemon.

export type McpStatus = "connected" | "failed" | "needs-auth" | "pending" | "disabled" | "unknown";
export type McpTool = { name: string; description: string; readOnly?: boolean; destructive?: boolean };
export type McpServerView = {
  name: string;
  status: McpStatus;
  version?: string;
  scope?: string; // user | project | local | claudeai | plugin | …
  error?: string;
  toolCount: number;
  tools: McpTool[];
};
export type McpSummary = { servers: McpServerView[]; truncated: boolean };

const STATUSES = new Set(["connected", "failed", "needs-auth", "pending", "disabled"]);
const MAX_SERVERS = 50;
const MAX_TOOLS_TOTAL = 400; // keeps the frame small however many tools a server exposes
const clip = (s: unknown, n: number): string => (typeof s === "string" ? s.replace(/\s+/g, " ").trim().slice(0, n) : "");

export function summarizeMcp(raw: unknown): McpSummary {
  if (!Array.isArray(raw)) return { servers: [], truncated: false };
  const servers: McpServerView[] = [];
  let budget = MAX_TOOLS_TOTAL;
  let truncated = raw.length > MAX_SERVERS;
  for (const r of raw.slice(0, MAX_SERVERS)) {
    const s = r as Record<string, unknown> | null;
    if (!s || typeof s.name !== "string" || !s.name) continue;
    const allTools = Array.isArray(s.tools) ? s.tools : [];
    const tools: McpTool[] = [];
    for (const t of allTools) {
      const tool = t as Record<string, unknown> | null;
      if (!tool || typeof tool.name !== "string") continue;
      if (budget-- <= 0) {
        truncated = true;
        break;
      }
      const ann = (tool.annotations ?? {}) as Record<string, unknown>;
      tools.push({
        name: clip(tool.name, 120),
        description: clip(tool.description, 120),
        ...(ann.readOnly === true ? { readOnly: true } : {}),
        ...(ann.destructive === true ? { destructive: true } : {}),
      });
    }
    const info = (s.serverInfo ?? {}) as Record<string, unknown>;
    servers.push({
      name: clip(s.name, 200),
      status: typeof s.status === "string" && STATUSES.has(s.status) ? (s.status as McpStatus) : "unknown",
      ...(typeof info.version === "string" ? { version: clip(info.version, 40) } : {}),
      ...(typeof (s.scope ?? s.source) === "string" ? { scope: clip(s.scope ?? s.source, 40) } : {}),
      ...(typeof s.error === "string" && s.error ? { error: clip(s.error, 200) } : {}),
      toolCount: allTools.length,
      tools,
    });
  }
  return { servers, truncated };
}

export const MCP_ACTIONS = ["reconnect", "enable", "disable"] as const;
export type McpAction = (typeof MCP_ACTIONS)[number];
export const parseMcpAction = (x: unknown): McpAction | null =>
  typeof x === "string" && (MCP_ACTIONS as readonly string[]).includes(x) ? (x as McpAction) : null;
