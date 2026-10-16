// File rewind (ADR 0023): POST /sessions/:id/rewind. A FAKE Agent SDK query stands
// in for the subprocess — the real-SDK behaviour is proven by spike-checkpoint.ts
// (docs/spikes/M8). Here we test the daemon's own guarantees: capability scoping,
// dry-run-first, the root check on the SDK's absolute paths, busy/in-flight
// refusal, audit, and the uuid plumbing.

import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { openDb } from "./db.js";
import { buildApp } from "./app.js";
import { createPairingCode } from "./auth.js";
import { ClaudeSession, type ClaudeRegistry } from "./claude.js";

const ROOT = mkdtempSync(join(tmpdir(), "vibe-ckpt-"));
const OUTSIDE = mkdtempSync(join(tmpdir(), "vibe-ckpt-out-"));
process.env.VIBE_PROJECT_ROOTS = ROOT;
const PROJ = join(ROOT, "proj");
mkdirSync(PROJ);

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
async function waitFor(fn: () => boolean, ms = 1500) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) {
    if (fn()) return;
    await sleep(5);
  }
  throw new Error("timed out waiting for condition");
}

function fakeWs() {
  const frames: any[] = [];
  return { OPEN: 1, readyState: 1, frames, send: (s: string) => frames.push(JSON.parse(s)), on() {}, ping() {}, terminate() {}, close() {} } as any;
}

// Fake SDK: records the options + every input message (uuid!) + every rewindFiles
// call. `hold` keeps the turn open (busy) until released.
function makeFake(opts: { files?: string[]; hold?: boolean } = {}) {
  const state = {
    options: null as any,
    inputs: [] as any[],
    rewinds: [] as { uuid: string; dryRun: boolean }[],
    release: () => {},
  };
  const files = opts.files ?? [join(PROJ, "a.txt")];
  const queryFn = (params: { prompt: AsyncIterable<any>; options: any }) => {
    // The titler also calls the injected queryFn (after turn 1); only the session's
    // own query (the one with canUseTool) is under test.
    if (!params.options?.canUseTool) return (async function* () {})();
    state.options = params.options;
    const gen: any = (async function* () {
      yield { type: "system", subtype: "init", session_id: "claude-1", model: "m" };
      for await (const m of params.prompt) {
        state.inputs.push(m);
        if (opts.hold) await new Promise<void>((r) => (state.release = r));
        yield { type: "result", subtype: "success", total_cost_usd: 0 };
      }
    })();
    gen.rewindFiles = async (uuid: string, o: { dryRun?: boolean } = {}) => {
      state.rewinds.push({ uuid, dryRun: !!o.dryRun });
      return o.dryRun
        ? { canRewind: true, filesChanged: files, insertions: 1, deletions: 2 }
        : { canRewind: true, skippedLinks: 0 };
    };
    return gen;
  };
  return { state, queryFn };
}

async function setup(fake = makeFake(), waitResult = true) {
  const db = openDb(":memory:");
  const registry: ClaudeRegistry = new Map();
  const app = await buildApp(db, undefined, registry);
  const { token } = (
    await app.inject({ method: "POST", url: "/pair", payload: { code: createPairingCode(db), device_name: "t" } })
  ).json();
  const auth = { authorization: `Bearer ${token}` };
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES (?,?,?,?)").run("p1", PROJ, "proj", "unknown");
  for (const id of ["s1", "s2"]) {
    db.prepare("INSERT INTO sessions (id, project_id, kind, status, created_at) VALUES (?,?,?,?,?)").run(id, "p1", "claude", "live", new Date().toISOString());
  }
  const ws = fakeWs();
  const s1 = new ClaudeSession(db, "s1", PROJ, fake.queryFn as any);
  s1.attach(ws);
  s1.start();
  registry.set("s1", s1);
  s1.pushUser("first", [], ws); // as session-ws does: the sender gets user_ack
  if (waitResult) await waitFor(() => ws.frames.some((f: any) => f.t === "result"));
  else await waitFor(() => fake.state.inputs.length === 1);
  const msgId = (db.prepare("SELECT id FROM messages WHERE session_id='s1' AND role='user'").get() as any).id as string;
  const rewind = (sid: string, body: unknown, headers = auth) =>
    app.inject({ method: "POST", url: `/sessions/${sid}/rewind`, headers, payload: body as any });
  return { db, app, registry, ws, s1, msgId, rewind, fake };
}

test("pushUser mints one uuid: stored in the row AND sent on the SDK message; checkpointing is on", async () => {
  const { db, fake } = await setup();
  const row = db.prepare("SELECT sdk_uuid FROM messages WHERE session_id='s1' AND role='user'").get() as any;
  assert.match(row.sdk_uuid, /^[0-9a-f-]{36}$/);
  assert.equal(fake.state.inputs[0].uuid, row.sdk_uuid);
  assert.equal(fake.state.options.enableFileCheckpointing, true);
});

test("pushUser acks the new row id so a live bubble can be rewound without a reattach", async () => {
  const { db, ws } = await setup();
  const row = db.prepare("SELECT id FROM messages WHERE session_id='s1' AND role='user'").get() as any;
  assert.deepEqual(ws.frames.filter((f: any) => f.t === "user_ack"), [{ t: "user_ack", messageId: row.id }]);
});

test("history frames carry the message id", async () => {
  const { db, s1, msgId } = await setup();
  const ws2 = fakeWs();
  s1.attach(ws2);
  const hist = ws2.frames.find((f: any) => f.t === "history");
  assert.equal(hist.messages.find((m: any) => m.role === "user").id, msgId);
  void db;
});

test("dry run lists files relative to the project and never rewinds for real", async () => {
  const { rewind, msgId, fake, db } = await setup();
  const r = await rewind("s1", { messageId: msgId, dryRun: true });
  assert.equal(r.statusCode, 200);
  const j = r.json();
  assert.deepEqual(j.filesChanged, ["a.txt"]);
  assert.equal(j.dryRun, true);
  assert.deepEqual(fake.state.rewinds.map((x) => x.dryRun), [true]);
  assert.ok(db.prepare("SELECT 1 FROM events WHERE kind='session.rewind.dry'").get());
});

test("a real rewind dry-runs FIRST, then rewinds, audits, and announces", async () => {
  const { rewind, msgId, fake, db, ws } = await setup();
  const r = await rewind("s1", { messageId: msgId, dryRun: false });
  assert.equal(r.statusCode, 200);
  const j = r.json();
  assert.equal(j.dryRun, false);
  assert.deepEqual(j.filesChanged, ["a.txt"]); // from the dry run — a real run returns no list
  assert.deepEqual(fake.state.rewinds.map((x) => x.dryRun), [true, false]);
  assert.ok(db.prepare("SELECT 1 FROM events WHERE kind='session.rewind'").get());
  const frame = ws.frames.find((f: any) => f.t === "rewound");
  assert.equal(frame.messageId, msgId);
  assert.deepEqual(frame.filesChanged, ["a.txt"]);
});

test("omitting dryRun defaults to a dry run (safe default)", async () => {
  const { rewind, msgId, fake } = await setup();
  const r = await rewind("s1", { messageId: msgId });
  assert.equal(r.json().dryRun, true);
  assert.deepEqual(fake.state.rewinds.map((x) => x.dryRun), [true]);
});

test("refuses when the SDK would touch files outside the project roots — real rewind never runs", async () => {
  const { rewind, msgId, fake, db } = await setup(makeFake({ files: [join(PROJ, "ok.txt"), join(OUTSIDE, "secret.txt")] }));
  const r = await rewind("s1", { messageId: msgId, dryRun: false });
  assert.equal(r.statusCode, 403);
  assert.deepEqual(r.json().files, [join(OUTSIDE, "secret.txt")]);
  assert.deepEqual(fake.state.rewinds.map((x) => x.dryRun), [true]); // never the real one
  assert.ok(db.prepare("SELECT 1 FROM events WHERE kind='session.rewind.denied'").get());
});

test("a symlink escaping the root is judged by its real path", async () => {
  const { symlinkSync } = await import("node:fs");
  const link = join(PROJ, "escape");
  symlinkSync(OUTSIDE, link);
  const { rewind, msgId, fake } = await setup(makeFake({ files: [join(link, "x.txt")] }));
  const r = await rewind("s1", { messageId: msgId, dryRun: false });
  assert.equal(r.statusCode, 403);
  assert.deepEqual(fake.state.rewinds.map((x) => x.dryRun), [true]);
});

test("another session's message id is a 404 (capability scoping)", async () => {
  const { rewind, msgId, db } = await setup();
  const r = await rewind("s2", { messageId: msgId });
  assert.equal(r.statusCode, 404);
  void db;
});

test("assistant rows, rows without a checkpoint uuid, and unknown ids are 404", async () => {
  const { rewind, db } = await setup();
  db.prepare("INSERT INTO messages (id, session_id, role, content, tool_json, ts) VALUES ('old','s1','user','legacy',NULL,'2020-01-01')").run();
  db.prepare("INSERT INTO messages (id, session_id, role, content, tool_json, ts, sdk_uuid) VALUES ('asst','s1','assistant','x',NULL,'2020-01-02','u-1')").run();
  for (const messageId of ["old", "asst", "nope"]) {
    assert.equal((await rewind("s1", { messageId })).statusCode, 404, messageId);
  }
});

test("bad bodies are 400; unknown session is 404; no token is 401", async () => {
  const { rewind, msgId } = await setup();
  assert.equal((await rewind("s1", {})).statusCode, 400);
  assert.equal((await rewind("s1", { messageId: msgId, dryRun: "yes" })).statusCode, 400);
  assert.equal((await rewind("zzz", { messageId: msgId })).statusCode, 404);
  assert.equal((await rewind("s1", { messageId: msgId }, {} as any)).statusCode, 401);
});

test("409 when the session is not running (reaped / never started)", async () => {
  const { rewind, msgId, registry } = await setup();
  registry.delete("s1");
  assert.equal((await rewind("s1", { messageId: msgId })).statusCode, 409);
});

test("409 mid-turn — nothing is rewound; works again once the turn ends", async () => {
  const { rewind, msgId, fake, ws } = await setup(makeFake({ hold: true }), false);
  const busy = await rewind("s1", { messageId: msgId, dryRun: false });
  assert.equal(busy.statusCode, 409);
  assert.deepEqual(fake.state.rewinds, []);
  fake.state.release();
  await waitFor(() => ws.frames.some((f: any) => f.t === "result"));
  assert.equal((await rewind("s1", { messageId: msgId })).statusCode, 200);
});

test("a worktree session may only rewind files inside its own checkout (ADR 0022)", async () => {
  // Same SDK file list (a file in the PARENT project) for both runs.
  const parentFile = join(PROJ, "a.txt");
  const plain = await setup(makeFake({ files: [parentFile] }));
  assert.equal((await plain.rewind("s1", { messageId: plain.msgId })).statusCode, 200);

  const wt = await setup(makeFake({ files: [parentFile] }));
  const wtDir = join(PROJ, ".vibe-worktrees", "s_000000000001");
  mkdirSync(wtDir, { recursive: true });
  wt.db.prepare("UPDATE sessions SET worktree_path = ? WHERE id = 's1'").run(wtDir);
  const r = await wt.rewind("s1", { messageId: wt.msgId });
  assert.equal(r.statusCode, 403, "the parent project is registered, but this session is isolated");
  assert.deepEqual(wt.fake.state.rewinds.map((x) => x.dryRun), [true]);
});
