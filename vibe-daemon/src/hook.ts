// Push for `claude` CLI sessions running outside the daemon (ADR 0014,
// security.md #18). A Claude Code `Notification` hook in ~/.claude/settings.json
// pipes its stdin JSON to this Unix socket; we push the same content-free
// `{type, sessionId}` the in-daemon sessions do (push.ts, ADR 0013).
//
// A Unix socket, not a route on the main port: `tailscale serve` proxies phone
// traffic to 127.0.0.1, so "came from localhost" proves nothing there. The
// socket is mode 600 — only the operator's own processes can reach it.

import { createServer, type Server } from "node:http";
import { chmodSync, mkdirSync, rmSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import type { DB } from "./db.js";
import type { ClaudeRegistry } from "./claude.js";
import { discoverExternalSessions } from "./discover.js";
import { Mirror, runningCliSessions } from "./external.js";
import { notifyDevices, type PushType } from "./push.js";

export const hookSocketPath = () =>
  process.env.VIBE_HOOK_SOCKET ?? join(homedir(), ".config", "vibe-daemon", "hook.sock");

// Claude Code notification_type → push type. Everything else (auth_success,
// quota…) isn't worth a buzz. No Stop hook: it fires every turn, which would
// buzz the phone while the operator sits at the PC; idle_prompt (~60 s of no
// reply) is the "you walked away" signal.
const TYPES: Record<string, PushType> = {
  permission_prompt: "cli_permission",
  elicitation_dialog: "cli_question",
  idle_prompt: "cli_waiting",
};

type Push = (db: DB, type: PushType, sessionId: string) => void;

// Returns why nothing was sent (for tests/logs), or "sent".
export function handleHook(db: DB, registry: ClaudeRegistry, body: unknown, push: Push = notifyDevices): string {
  const b = (body ?? {}) as { hook_event_name?: unknown; notification_type?: unknown; session_id?: unknown };
  if (b.hook_event_name !== "Notification" || typeof b.session_id !== "string") return "ignored";
  const type = TYPES[String(b.notification_type)];
  if (!type) return "ignored";
  // Only a live CLI outside the daemon. The Agent SDK loads user hooks too, so
  // the daemon's own sessions call here — they push themselves (claude.ts).
  const cli = runningCliSessions().get(b.session_id);
  if (!cli) return "not external";

  const find = () =>
    db.prepare("SELECT id FROM sessions WHERE claude_session_id = ?").get(cli.sessionId) as { id: string } | undefined;
  let row = find();
  if (!row) {
    // First we hear of it: register it the way GET /sessions would.
    const project = db.prepare("SELECT id, path FROM projects WHERE path = ?").get(cli.cwd) as
      | { id: string; path: string }
      | undefined;
    if (project) discoverExternalSessions(db, project, undefined, true);
    row = find();
  }
  if (!row) return "no row";
  if (registry.has(row.id) || Mirror.watching(row.id)) return "attached";
  push(db, type, row.id);
  return "sent";
}

export function startHookSocket(db: DB, registry: ClaudeRegistry, path = hookSocketPath()): Server {
  mkdirSync(dirname(path), { recursive: true });
  rmSync(path, { force: true }); // stale socket from a previous run
  const server = createServer((req, res) => {
    let raw = "";
    req.setEncoding("utf8");
    req.on("data", (c: string) => {
      raw += c;
      if (raw.length > 64 * 1024) req.destroy(); // hook stdin is small; don't buffer junk
    });
    req.on("end", () => {
      let result = "bad json";
      try {
        result = handleHook(db, registry, JSON.parse(raw));
      } catch (e) {
        if (!(e instanceof SyntaxError)) console.error("[vibe-daemon] hook failed:", (e as Error)?.message ?? e);
      }
      res.end(result);
    });
  });
  // umask so the socket is born 600 — no window where group/other can connect.
  const prev = process.umask(0o177);
  try {
    server.listen(path, () => chmodSync(path, 0o600));
  } finally {
    process.umask(prev);
  }
  return server;
}
