# 43 — Tools & integrations (MCP servers)

**Status:** implemented (daemon + app + tests 2026-10-07; on-device check pending)

See which MCP servers a chat has, whether they're up, what tools they offer, and reconnect or
turn one off. Evidence: [M15 spike](../spikes/M15-spike-mcp.md).

- **Wire** ([claude-ws.md](../protocols/claude-ws.md)): client → `get_mcp` (on demand — tool lists
  can be big) and `mcp_action {server, action}` (`reconnect|enable|disable`); server → `mcp`
  `{servers:[{name, status, version?, scope?, error?, toolCount, tools:[{name, description,
  readOnly?, destructive?}]}], truncated}`. Claude engine only.
- **Daemon** (`mcp.ts`, `ClaudeSession.sendMcpStatus` / `mcpAction`): **never forwards the SDK's
  `config`** (launch command, args, env, URLs — the spike shows they hold secrets); clips text,
  caps at 50 servers / 400 tools in total (the real `toolCount` is still sent). An action runs
  only for a server name the SDK itself lists, is whitelisted, always refreshes the view, and is
  audited `session.mcp` with its outcome (`ok`/`failed`) — a rejected re-enable still changed
  state.
- **App:** "Tools & integrations…" in the chat menu → `McpSheet`: status icon and one-line summary
  per server, expand for tools (read-only / "can change things" marks), the error, and for
  `needs-auth` an honest note that authorization can't be done from the phone; per-server menu
  (Reconnect where it applies, Turn off for this chat / Turn on).
- **Scope of a change:** turning a server off affects this chat's SDK process only; the project's
  `.mcp.json` / settings are never edited.

**Not built, on purpose:** hooks. They're shell commands in settings files (may contain secrets) and
editing them from a phone is remote-code-execution configuration — see the spike; needs its own ADR.
Also out of scope: adding or removing servers, OAuth for connectors, per-tool permission rules.

Tests: `vibe-daemon/src/mcp.test.ts`, `app/test/mcp_test.dart`.
