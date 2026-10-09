// Proposal 30 spike — prove: a REAL Agent SDK session sees the in-process
// `vibe-peers` MCP tools, can list a sibling and send it a message, and the send
// goes through canUseTool/the gate. The sibling is a recording stand-in.
//
// Re-run: pnpm tsx src/spike-peers.ts

import { openDb } from "./db.js";
import { ClaudeSession } from "./claude.js";
import type { EngineSession } from "./engine.js";

const db = openDb(":memory:");
db.prepare("INSERT INTO projects (id, path, name, type) VALUES (?,?,?,?)").run("p1", "/tmp", "p", "unknown");
const ins = db.prepare("INSERT INTO sessions (id, project_id, kind, status, title, created_at) VALUES (?,?,?,?,?,?)");
const t = new Date().toISOString();
ins.run("s_aaa", "p1", "claude", "live", "Sender", t);
ins.run("s_bbb", "p1", "claude", "live", "Receiver", t);

const registry = new Map<string, EngineSession>();
let received: string | null = null;
registry.set("s_bbb", { pushUser: (x: string) => (received = x) } as unknown as EngineSession);

const ask = process.argv[2] === "ask"; // ask mode: the send must wait for a phone approval
const frames: any[] = [];
const ws: any = { OPEN: 1, readyState: 1, send: (x: string) => frames.push(JSON.parse(x)), on() {}, ping() {}, terminate() {}, close() {} };
const a = new ClaudeSession(db, "s_aaa", "/tmp", undefined, undefined, null, ask ? "ask" : "auto");
if (ask) a.attach(ws);
a.peerRegistry = registry;
registry.set("s_aaa", a);
a.start();
a.pushUser(
  "Use your list_sessions tool to find the other session, then use send_message to send it exactly: ping from spike. " +
    "Then reply with the single word DONE.",
);

const t0 = Date.now();
while (received === null && Date.now() - t0 < 90_000) {
  await new Promise((r) => setTimeout(r, 250));
  // Ask mode: play the phone — approve each card, noting what was asked.
  for (const f of frames.splice(0)) {
    if (f.t === "permission_request") {
      console.log(`[spike] approval card: ${f.toolName} delivered-so-far=${received !== null}`);
      a.onPermission(f.toolUseID, true, "spike-device");
    }
  }
}
console.log(received ? `[spike] PASS after ${((Date.now() - t0) / 1000).toFixed(1)}s\n${received}` : "[spike] FAIL: nothing delivered");
const ev = db.prepare("SELECT kind, detail FROM events WHERE kind IN ('peer.send') OR detail LIKE '%vibe-peers%'").all();
console.log("[spike] audit:", JSON.stringify(ev));
a.stop();
process.exit(received ? 0 : 1);
