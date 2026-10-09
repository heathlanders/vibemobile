// Conversation fork (proposal 42, M14 spike): planFork is pure; the route runs against a
// scripted SDK (forkSession / getSessionMessages) through the real app.

import test from "node:test";
import assert from "node:assert/strict";
process.env.VIBE_PROJECT_ROOTS = "/home/user"; // the scripted project lives under it
import { openDb } from "./db.js";
import { buildApp } from "./app.js";
import { createPairingCode } from "./auth.js";
import { _setForkDepsForTest, planFork } from "./fork.js";
import type { ClaudeRegistry } from "./claude.js";

type R = { id: string; role: string; content: string | null; tool_json: string | null; ts: string; sdk_uuid: string | null };
const row = (id: string, role: string, sdk_uuid: string | null = null): R => ({ id, role, content: id, tool_json: null, ts: `2026-01-01T00:00:${id.padStart(2, "0")}Z`, sdk_uuid });

// Two turns: u1 -> a1 (with a tool in between), u2 -> a2. Transcript = user/assistant only.
const ROWS = [row("1", "user", "U1"), row("2", "assistant"), row("3", "tool"), row("4", "result"), row("5", "user", "U2"), row("6", "assistant"), row("7", "result")];
const TRANSCRIPT = [{ uuid: "U1" }, { uuid: "A1" }, { uuid: "T1" }, { uuid: "A1b" }, { uuid: "U2" }, { uuid: "A2" }];

test("planFork after (default): keeps the turn and its reply, cuts at the message before the NEXT user turn", () => {
  assert.deepEqual(planFork(ROWS, TRANSCRIPT, "1", "after"), { rowCount: 4, upToMessageId: "A1b" });
});

test("planFork after the LAST turn copies everything (no SDK cut)", () => {
  assert.deepEqual(planFork(ROWS, TRANSCRIPT, "5", "after"), { rowCount: 7 });
});

test("planFork before: everything prior to that user message", () => {
  assert.deepEqual(planFork(ROWS, TRANSCRIPT, "5", "before"), { rowCount: 4, upToMessageId: "A1b" });
});

test("planFork before the FIRST message is refused — there is nothing to keep", () => {
  assert.match((planFork(ROWS, TRANSCRIPT, "1", "before") as { error: string }).error, /nothing before the first message/);
});

test("planFork refuses what it can't map: unknown id, non-user row, user row without a checkpoint, out-of-step transcript", () => {
  for (const id of ["nope", "2", "3", "7"]) assert.match((planFork(ROWS, TRANSCRIPT, id, "after") as { error: string }).error, /no checkpoint/, id);
  const legacy = [row("1", "user"), row("2", "assistant")];
  assert.match((planFork(legacy, TRANSCRIPT, "1", "after") as { error: string }).error, /no checkpoint/);
  // a later user turn sent from a terminal (no uuid) can't be located
  const mixed = [row("1", "user", "U1"), row("2", "assistant"), row("3", "user")];
  assert.match((planFork(mixed, TRANSCRIPT, "1", "after") as { error: string }).error, /no checkpoint/);
  assert.match((planFork(ROWS, [{ uuid: "U1" }], "1", "after") as { error: string }).error, /out of step/);
  assert.match((planFork(ROWS, [], "5", "before") as { error: string }).error, /not in the saved conversation/);
});

// ---- route ------------------------------------------------------------------------------------

async function setup(opts: { claudeId?: string | null; worktree?: string | null; model?: string | null } = {}) {
  const db = openDb(":memory:");
  const registry: ClaudeRegistry = new Map();
  const app = await buildApp(db, undefined, registry);
  const { token } = (await app.inject({ method: "POST", url: "/pair", payload: { code: createPairingCode(db), device_name: "t" } })).json();
  const auth = { authorization: `Bearer ${token}` };
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES ('p','/home/user/vibemobile','p','unknown')").run();
  db.prepare(
    "INSERT INTO sessions (id, project_id, kind, status, created_at, title, model, mode, effort, claude_session_id, worktree_path) VALUES ('s','p','claude','live',?,?,?,?,?,?,?)",
  ).run("2026-01-01T00:00:00Z", "Original", opts.model ?? null, "plan", "high", opts.claudeId === undefined ? "sdk-orig" : opts.claudeId, opts.worktree ?? null);
  const ins = db.prepare("INSERT INTO messages (id, session_id, role, content, tool_json, ts, sdk_uuid) VALUES (?,?,?,?,?,?,?)");
  for (const r of ROWS) ins.run(`m${r.id}`, "s", r.role, r.content, r.tool_json, r.ts, r.sdk_uuid);
  const calls: { fork: any[]; messages: any[] } = { fork: [], messages: [] };
  _setForkDepsForTest({
    messages: async (sid, o) => (calls.messages.push([sid, o]), TRANSCRIPT as any),
    fork: async (sid, o) => (calls.fork.push([sid, o]), { sessionId: "sdk-fork-1" }),
  });
  const post = (body: unknown, headers: Record<string, string> = auth, sid = "s") =>
    app.inject({ method: "POST", url: `/sessions/${sid}/fork`, headers, payload: body as any });
  return { db, app, registry, calls, post };
}
test.afterEach(() => _setForkDepsForTest(null));

test("fork after: new resumable session, copied history, SDK told the exact cut; original untouched", async () => {
  const { post, db, calls } = await setup();
  const r = await post({ messageId: "m1" });
  assert.equal(r.statusCode, 201);
  const j = r.json();
  assert.equal(j.copied, 4);
  assert.deepEqual(calls.fork[0], ["sdk-orig", { dir: "/home/user/vibemobile", upToMessageId: "A1b", title: "Original (branch)" }]);
  const row = db.prepare("SELECT * FROM sessions WHERE id = ?").get(j.id) as any;
  assert.deepEqual([row.claude_session_id, row.status, row.title, row.mode, row.effort, row.kind], ["sdk-fork-1", "stale", "↳ Original", "plan", "high", "claude"]);
  assert.notEqual(j.id, "s");
  const copied = db.prepare("SELECT id, role, content, sdk_uuid FROM messages WHERE session_id = ? ORDER BY ts").all(j.id) as any[];
  assert.deepEqual(copied.map((m) => m.role), ["user", "assistant", "tool", "result"]);
  assert.ok(copied.every((m) => m.sdk_uuid === null), "uuids/checkpoints don't follow a fork");
  assert.ok(copied.every((m) => !m.id.startsWith("m")), "fresh row ids");
  assert.equal((db.prepare("SELECT COUNT(*) n FROM messages WHERE session_id='s'").get() as any).n, 7, "original intact");
  assert.ok(db.prepare("SELECT 1 FROM events WHERE kind='session.fork'").get());
});

test("fork before: keeps only what precedes that message", async () => {
  const { post, calls } = await setup();
  const r = await post({ messageId: "m5", at: "before" });
  assert.equal(r.statusCode, 201);
  assert.equal(r.json().copied, 4);
  assert.equal(calls.fork[0][1].upToMessageId, "A1b");
});

test("fork after the last turn is a full copy (no SDK cut)", async () => {
  const { post, calls } = await setup();
  const r = await post({ messageId: "m5" });
  assert.equal(r.json().copied, 7);
  assert.equal(calls.fork[0][1].upToMessageId, undefined);
});

test("refusals: bad body 400, unknown session 404, foreign/legacy message 404, no claude id 409, worktree 400, native 400, busy 409", async () => {
  const s = await setup();
  assert.equal((await s.post({})).statusCode, 400);
  assert.equal((await s.post({ messageId: "m1", at: "sideways" })).statusCode, 400);
  assert.equal((await s.post({ messageId: "m1" }, undefined, "zzz")).statusCode, 404);
  assert.equal((await s.post({ messageId: "m2" })).statusCode, 404, "an assistant row");
  assert.equal((await s.post({ messageId: "nope" })).statusCode, 404);
  s.registry.set("s", { busy: () => true } as any);
  assert.equal((await s.post({ messageId: "m1" })).statusCode, 409, "a turn is running");
  assert.equal(s.calls.fork.length, 0, "nothing forked by any refusal");
  assert.equal((await setup({ claudeId: null }).then((x) => x.post({ messageId: "m1" }))).statusCode, 409);
  assert.equal((await setup({ worktree: "/x/.vibe-worktrees/s" }).then((x) => x.post({ messageId: "m1" }))).statusCode, 400);
  assert.equal((await setup({ model: "openai:gpt-4o" }).then((x) => x.post({ messageId: "m1" }))).statusCode, 400);
});

test("a project outside the allowed roots is refused (403), nothing forked", async () => {
  const { post, db, calls } = await setup();
  db.prepare("UPDATE projects SET path = '/etc' WHERE id = 'p'").run();
  assert.equal((await post({ messageId: "m1" })).statusCode, 403);
  assert.equal(calls.fork.length, 0);
});

test("an SDK failure creates nothing and leaks no detail", async () => {
  const { post, db } = await setup();
  _setForkDepsForTest({ messages: async () => TRANSCRIPT as any, fork: async () => { throw new Error("ENOENT /secret/path"); } });
  const r = await post({ messageId: "m1" });
  assert.equal(r.statusCode, 500);
  assert.doesNotMatch(r.body, /secret|ENOENT/);
  assert.equal((db.prepare("SELECT COUNT(*) n FROM sessions").get() as any).n, 1);
  _setForkDepsForTest({ messages: async () => { throw new Error("boom"); }, fork: async () => ({ sessionId: "x" }) });
  assert.equal((await post({ messageId: "m1" })).statusCode, 500);
});

test("fork needs the bearer token", async () => {
  const { post } = await setup();
  assert.equal((await post({ messageId: "m1" }, {})).statusCode, 401);
});
