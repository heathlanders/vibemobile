# M15 spike — MCP servers over the Agent SDK

**Question (gap analysis):** every mainstream harness shows which MCP/tool servers are
connected. What does the SDK report, and what is safe to forward to a phone?

**Script:** `vibe-daemon/src/spike-mcp.ts` — throwaway temp-dir cwd with a deliberately broken
`.mcp.json` (a non-existent command, carrying a fake secret in `args` and `env`); SDK 0.3.291; no
model call. Run 2026-10-07.

## Results

| # | Question | Result |
|---|----------|--------|
| a | `Query.mcpServerStatus()` fields | `name, status, config, scope, source` (+ `serverInfo`, `error`, `tools` when relevant). Statuses: `connected \| failed \| needs-auth \| pending \| disabled`. |
| b | **Does `config` carry secrets?** | **Yes.** The fake secret from the server's `args` and `env` is present in the status. For HTTP servers `config` holds the URL, which can embed tokens. → the daemon must never forward `config`. |
| c | A server that can't start | `status: failed` with `error: ENOENT: … posix_spawn '/nonexistent/mcp-server'`. |
| d | `reconnectMcpServer` on it | **Rejects** with the same error; state stays `failed`. |
| e | `toggleMcpServer(name, false)` | Resolves; state becomes `disabled`. |
| f | `toggleMcpServer(name, true)` on a server that still can't start | **Rejects** (it re-tries and fails again) — but the action *was* carried out; state goes `disabled → failed`. So a rejection is not "nothing happened". |
| g | claude.ai connectors | `needs-auth` (Gmail, Drive, Calendar, Stripe plugin) — OAuth can't be completed non-interactively; `connected` for Claude Docs. |
| h | Hooks | Not listed by any query method; they exist only in settings files as shell commands (which can contain secrets). |

## Consequences

- Forward name, status, version, scope, a clipped error and the tool list (name, short
  description, `readOnly` / `destructive` annotations). **Nothing from `config`.**
- Offer only `reconnect`, `enable`, `disable`, only for a name the SDK itself just listed.
- Audit every permitted attempt with its outcome (`ok` / `failed`) — (f) means a rejection still
  changed state.
- **Hooks are deliberately not built.** There is no safe listing, showing a hook would show its
  command (possibly with secrets), and *editing* hooks from a phone is remote-code-execution
  configuration: it needs its own ADR and threat model.

## Re-run

```
cd vibe-daemon && npx tsx src/spike-mcp.ts
```
