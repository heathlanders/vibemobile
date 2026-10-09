// Session modes (proposal 25): ask / auto / plan. Fake Agent SDK (no spend); the
// real-SDK behavior these tests assume (setPermissionMode over streaming input,
// ExitPlanMode through canUseTool, allow leaves plan, deny stays) was proven by
// spike-plan-mode.ts — see docs/spikes/M7-spike-plan-mode.md.

import { REPO_DIR } from "./test-paths.js";
import test from "node:test";
import assert from "node:assert/strict";
import { openDb } from "./db.js";
import { ClaudeSession } from "./claude.js";
import { NativeSession } from "./native.js";
import { parseMode } from "./engine.js";
import { buildApp } from "./app.js";
import { createPairingCode } from "./auth.js";

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
  return {
    OPEN: 1,
    readyState: 1,
    frames,
    send: (s: string) => frames.push(JSON.parse(s)),
    on() {},
    ping() {},
    terminate() {},
    close() {},
  } as any;
}

function seedDb() {
  const db = openDb(":memory:");
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES (?,?,?,?)").run("p1", "/tmp", "p", "unknown");
  db.prepare("INSERT INTO sessions (id, project_id, kind, status, created_at) VALUES (?,?,?,?,?)").run(
    "s1",
    "p1",
    "claude",
    "live",
    new Date().toISOString(),
  );
  return db;
}

// A fake SDK whose Query records setPermissionMode calls and the options it got.
// `script` runs after the first user turn with access to options (canUseTool).
function recordingQuery(script: (options: any) => AsyncGenerator<any>) {
  const calls: { modes: string[]; options: any } = { modes: [], options: null };
  const fn = (params: { prompt: AsyncIterable<any>; options: any }) => {
    calls.options = params.options;
    const gen: any = (async function* () {
      yield { type: "system", subtype: "init", session_id: "claude-m", model: "claude-x" };
      const it = params.prompt[Symbol.asyncIterator]();
      await it.next();
      yield* script(params.options);
      yield { type: "result", subtype: "success", total_cost_usd: 0 };
    })();
    gen.setPermissionMode = async (m: string) => {
      calls.modes.push(m);
    };
    return gen;
  };
  return { fn, calls };
}

const idle = () => recordingQuery(async function* () {});

test("parseMode whitelists exactly ask/auto/plan", () => {
  assert.equal(parseMode("plan"), "plan");
  assert.equal(parseMode("ask"), "ask");
  assert.equal(parseMode("auto"), "auto");
  for (const bad of ["bypassPermissions", "acceptEdits", "default", "", null, undefined, 3, {}]) {
    assert.equal(parseMode(bad), null);
  }
});

test("attach sends the current mode with the available list", () => {
  const db = seedDb();
  const ws = fakeWs();
  const s = new ClaudeSession(db, "s1", "/tmp", idle().fn as any);
  s.attach(ws);
  const f = ws.frames.find((x: any) => x.t === "mode");
  assert.deepEqual(f, { t: "mode", mode: "auto", available: ["ask", "auto", "plan"] });
});

test("initial mode maps to the SDK permissionMode and gate", async () => {
  for (const [mode, sdk] of [
    ["plan", "plan"],
    ["ask", "default"],
    ["auto", "default"],
  ] as const) {
    const db = seedDb();
    const q = idle();
    const s = new ClaudeSession(db, "s1", "/tmp", q.fn as any, undefined, null, mode);
    s.start();
    assert.equal(q.calls.options.permissionMode, sdk, mode);
    s.stop();
  }
});

test("setMode switches the SDK live, persists, audits the device, and tells the client", async () => {
  const db = seedDb();
  const q = idle();
  const ws = fakeWs();
  const s = new ClaudeSession(db, "s1", "/tmp", q.fn as any);
  s.attach(ws);
  s.start();
  assert.equal(s.setMode("plan", "dev1"), true);
  assert.deepEqual(q.calls.modes, ["plan"]);
  assert.equal((db.prepare("SELECT mode FROM sessions WHERE id='s1'").get() as any).mode, "plan");
  const ev = db.prepare("SELECT device_id, detail FROM events WHERE kind='session.mode'").get() as any;
  assert.equal(ev.detail, "s1:plan");
  assert.equal(ev.device_id, "dev1");
  assert.ok(ws.frames.some((f: any) => f.t === "mode" && f.mode === "plan"));
  assert.equal(s.setMode("plan"), false, "no-op when unchanged");
  s.stop();
});

test("ask mode round-trips tool calls; switching to auto flushes the waiting one", async () => {
  const db = seedDb();
  const q = recordingQuery(async function* (options) {
    await options.canUseTool("Read", { file: "x" }, { toolUseID: "tu1" });
  });
  const ws = fakeWs();
  const s = new ClaudeSession(db, "s1", "/tmp", q.fn as any, undefined, null, "ask");
  s.attach(ws);
  s.start();
  s.pushUser("go");
  await waitFor(() => ws.frames.some((f: any) => f.t === "permission_request"));
  s.setMode("auto"); // flushes the waiting request
  await waitFor(() => ws.frames.some((f: any) => f.t === "result"));
  s.stop();
});

test("ExitPlanMode round-trips to the phone even with auto-allow on; approve returns to the chosen mode", async () => {
  const db = seedDb();
  let decision: any = null;
  const q = recordingQuery(async function* (options) {
    decision = await options.canUseTool("ExitPlanMode", { plan: "# P\n- step", planFilePath: "/x/p.md" }, { toolUseID: "tu9" });
  });
  const ws = fakeWs();
  const s = new ClaudeSession(db, "s1", "/tmp", q.fn as any, undefined, null, "plan");
  s.attach(ws);
  s.start();
  s.pushUser("plan it");
  await waitFor(() => ws.frames.some((f: any) => f.t === "user_dialog"));
  const dlg = ws.frames.find((f: any) => f.t === "user_dialog");
  assert.equal(dlg.dialogKind, "exit_plan");
  assert.equal(dlg.payload.plan, "# P\n- step");
  assert.equal(decision, null, "not auto-approved");
  assert.equal(s.pending().dialogs.length, 1, "pending → pushed/replayed like AskUserQuestion");

  assert.equal(s.onDialogResponse(dlg.dialogId, true, { approve: true, mode: "ask" }, "dev1"), true);
  await waitFor(() => decision !== null);
  assert.equal(decision.behavior, "allow");
  assert.deepEqual(decision.updatedInput, { plan: "# P\n- step", planFilePath: "/x/p.md" });
  assert.ok(ws.frames.some((f: any) => f.t === "mode" && f.mode === "ask"));
  assert.deepEqual(q.calls.modes, ["default"]);
  const ev = db.prepare("SELECT device_id FROM events WHERE kind='session.mode'").get() as any;
  assert.equal(ev.device_id, "dev1", "mode switch attributed to the approving device");
  s.stop();
});

test("approving a plan with no mode picked returns to the pre-plan mode", async () => {
  const db = seedDb();
  let decision: any = null;
  const q = recordingQuery(async function* (options) {
    decision = await options.canUseTool("ExitPlanMode", { plan: "p" }, {});
  });
  const ws = fakeWs();
  const s = new ClaudeSession(db, "s1", "/tmp", q.fn as any, undefined, null, "ask");
  s.attach(ws);
  s.start();
  s.setMode("plan");
  s.pushUser("x");
  await waitFor(() => ws.frames.some((f: any) => f.t === "user_dialog"));
  s.onDialogResponse(ws.frames.find((f: any) => f.t === "user_dialog").dialogId, true, { approve: true });
  await waitFor(() => decision !== null);
  assert.equal(ws.frames.filter((f: any) => f.t === "mode").pop().mode, "ask");
  s.stop();
});

test("rejecting a plan denies with the feedback and stays in plan", async () => {
  const db = seedDb();
  let decision: any = null;
  const q = recordingQuery(async function* (options) {
    decision = await options.canUseTool("ExitPlanMode", { plan: "p" }, {});
  });
  const ws = fakeWs();
  const s = new ClaudeSession(db, "s1", "/tmp", q.fn as any, undefined, null, "plan");
  s.attach(ws);
  s.start();
  s.pushUser("x");
  await waitFor(() => ws.frames.some((f: any) => f.t === "user_dialog"));
  s.onDialogResponse(ws.frames.find((f: any) => f.t === "user_dialog").dialogId, true, {
    approve: false,
    feedback: "cover error handling",
  });
  await waitFor(() => decision !== null);
  assert.deepEqual(decision, { behavior: "deny", message: "cover error handling" });
  assert.equal(ws.frames.filter((f: any) => f.t === "mode").pop().mode, "plan");
  assert.deepEqual(q.calls.modes, []);
  s.stop();
});

test("a plan approval does not override a mode the user switched to meanwhile", async () => {
  const db = seedDb();
  let decision: any = null;
  const q = recordingQuery(async function* (options) {
    decision = await options.canUseTool("ExitPlanMode", { plan: "p" }, {});
  });
  const ws = fakeWs();
  const s = new ClaudeSession(db, "s1", "/tmp", q.fn as any, undefined, null, "plan");
  s.attach(ws);
  s.start();
  s.pushUser("x");
  await waitFor(() => ws.frames.some((f: any) => f.t === "user_dialog"));
  s.setMode("ask");
  s.onDialogResponse(ws.frames.find((f: any) => f.t === "user_dialog").dialogId, true, { approve: true, mode: "auto" });
  await waitFor(() => decision !== null);
  assert.equal(decision.behavior, "allow");
  assert.equal(ws.frames.filter((f: any) => f.t === "mode").pop().mode, "ask");
  s.stop();
});

test("legacy auto_allow never moves a session out of plan", () => {
  const db = seedDb();
  const q = idle();
  const s = new ClaudeSession(db, "s1", "/tmp", q.fn as any, undefined, null, "plan");
  s.start();
  s.setAutoAllow(true);
  s.setAutoAllow(false);
  assert.deepEqual(q.calls.modes, []);
  assert.equal((db.prepare("SELECT mode FROM sessions WHERE id='s1'").get() as any)?.mode ?? null, null);
  s.stop();
});

test("native engine supports ask/auto only", () => {
  const db = seedDb();
  const s = new NativeSession(db, "s1", "/tmp", "openai:gpt-4o", (() => {}) as any);
  const ws = fakeWs();
  s.attach(ws);
  assert.deepEqual(ws.frames.find((f: any) => f.t === "mode"), { t: "mode", mode: "auto", available: ["ask", "auto"] });
  assert.equal(s.setMode("plan"), false);
  assert.equal(s.setMode("ask", "dev1"), true);
  assert.ok(ws.frames.some((f: any) => f.t === "mode" && f.mode === "ask"));
  s.stop();
});

test("POST /sessions mode: whitelisted, claude only, persisted", async () => {
  const db = openDb(":memory:");
  const app = await buildApp(db, { live: new Map(), async sweepStale() {} } as any, new Map());
  const { token } = (
    await app.inject({ method: "POST", url: "/pair", payload: { code: createPairingCode(db), device_name: "t" } })
  ).json();
  const auth = { authorization: `Bearer ${token}` };
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES (?,?,?,?)").run("p_ok", REPO_DIR, "v", "unknown");
  const post = (payload: unknown) => app.inject({ method: "POST", url: "/sessions", headers: auth, payload });

  const ok = await post({ project_id: "p_ok", kind: "claude", mode: "plan" });
  assert.equal(ok.statusCode, 201);
  assert.equal((db.prepare("SELECT mode FROM sessions WHERE id = ?").get(ok.json().id) as any).mode, "plan");

  assert.equal((await post({ project_id: "p_ok", kind: "claude", mode: "bypassPermissions" })).statusCode, 400);
  assert.equal((await post({ project_id: "p_ok", kind: "terminal", mode: "plan" })).statusCode, 400);
  const none = await post({ project_id: "p_ok", kind: "claude" });
  assert.equal((db.prepare("SELECT mode FROM sessions WHERE id = ?").get(none.json().id) as any).mode, null);
});
