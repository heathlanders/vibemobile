// CLI-session push hook (ADR 0014, security.md #18). A real `sleep` process
// stands in for a running `claude` CLI in a temp session registry.

import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { request } from "node:http";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { openDb } from "./db.js";
import { encodeProjectPath } from "./discover.js";
import { handleHook, startHookSocket } from "./hook.js";
import type { PushType } from "./push.js";
import type { EngineSession } from "./engine.js";

const tmp = mkdtempSync(join(tmpdir(), "vibe-hook-"));
const projectDir = join(tmp, "proj");
const sessionsDir = join(tmp, "sessions");
const claudeRoot = join(tmp, "projects");
mkdirSync(projectDir);
mkdirSync(sessionsDir);
process.env.VIBE_CLAUDE_SESSIONS_DIR = sessionsDir;
process.env.VIBE_CLAUDE_PROJECTS_DIR = claudeRoot;

// Via a shell that exits, so the process isn't our child — runningCliSessions
// drops the daemon's own children (its Agent SDK subprocess).
const cli = { pid: Number(execFileSync("sh", ["-c", "sleep 60 >/dev/null 2>&1 & echo $!"], { encoding: "utf8" })) };
test.after(() => {
  process.kill(cli.pid);
  rmSync(tmp, { recursive: true, force: true });
});
const procStart = (pid: number) => {
  const s = readFileSync(`/proc/${pid}/stat`, "utf8");
  return s.slice(s.lastIndexOf(")") + 2).split(" ")[19];
};
writeFileSync(
  join(sessionsDir, `${cli.pid}.json`),
  JSON.stringify({ pid: cli.pid, sessionId: "cli-1", cwd: projectDir, procStart: procStart(cli.pid), status: "idle" }),
);

function setup() {
  const db = openDb(":memory:");
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES (?,?,?,?)").run("p1", projectDir, "proj", "unknown");
  const sent: [PushType, string][] = [];
  const push = (_db: unknown, type: PushType, id: string) => void sent.push([type, id]);
  return { db, sent, push };
}
const note = (notification_type: string, session_id = "cli-1") => ({
  hook_event_name: "Notification",
  notification_type,
  session_id,
  cwd: projectDir,
});

test("a CLI permission prompt pushes for its row, discovering it on first contact", () => {
  const { db, sent, push } = setup();
  mkdirSync(join(claudeRoot, encodeProjectPath(projectDir)), { recursive: true });
  writeFileSync(join(claudeRoot, encodeProjectPath(projectDir), "cli-1.jsonl"), "");
  assert.equal(handleHook(db, new Map(), note("permission_prompt"), push), "sent");
  const row = db.prepare("SELECT id FROM sessions WHERE claude_session_id = 'cli-1'").get() as { id: string };
  assert.deepEqual(sent, [["cli_permission", row.id]]);
});

test("notification types map to push types; the rest are ignored", () => {
  const { db, sent, push } = setup();
  db.prepare("INSERT INTO sessions (id, project_id, kind, claude_session_id, status, created_at) VALUES (?,?,?,?,?,?)").run(
    "s1", "p1", "claude", "cli-1", "stale", new Date().toISOString(),
  );
  handleHook(db, new Map(), note("elicitation_dialog"), push);
  handleHook(db, new Map(), note("idle_prompt"), push);
  assert.equal(handleHook(db, new Map(), note("auth_success"), push), "ignored");
  assert.equal(handleHook(db, new Map(), { ...note("idle_prompt"), hook_event_name: "Stop" }, push), "ignored");
  assert.equal(handleHook(db, new Map(), null, push), "ignored");
  assert.deepEqual(sent, [["cli_question", "s1"], ["cli_waiting", "s1"]]);
});

test("no push for a session that isn't a running external CLI, or that the daemon owns", () => {
  const { db, sent, push } = setup();
  db.prepare("INSERT INTO sessions (id, project_id, kind, claude_session_id, status, created_at) VALUES (?,?,?,?,?,?)").run(
    "s1", "p1", "claude", "cli-1", "live", new Date().toISOString(),
  );
  // Not in the CLI registry (e.g. the daemon's own Agent SDK child, or a dead pid).
  assert.equal(handleHook(db, new Map(), note("permission_prompt", "other"), push), "not external");
  // The daemon runs it: claude.ts pushes (or the phone is attached).
  const registry = new Map([["s1", {} as EngineSession]]);
  assert.equal(handleHook(db, registry, note("permission_prompt"), push), "attached");
  assert.deepEqual(sent, []);
});

test("the Unix socket is mode 600 and answers the hook's POST", async () => {
  const { db } = setup();
  const path = join(tmp, "hook.sock");
  const server = startHookSocket(db, new Map(), path);
  await new Promise((r) => server.once("listening", r));
  assert.equal(statSync(path).mode & 0o777, 0o600);
  const post = (body: string) =>
    new Promise<string>((resolve, reject) => {
      const req = request({ socketPath: path, method: "POST", path: "/hook" }, (res) => {
        let out = "";
        res.on("data", (c) => (out += c));
        res.on("end", () => resolve(out));
      });
      req.on("error", reject);
      req.end(body);
    });
  assert.equal(await post(JSON.stringify(note("auth_success"))), "ignored");
  assert.equal(await post("not json"), "bad json");
  await new Promise((r) => server.close(r));
});
