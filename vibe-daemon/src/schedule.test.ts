// Scheduled prompts (proposal 44): pure timetable maths, validation, the routes, and the
// safety rules of an unattended run.

process.env.TZ = "UTC"; // the timetable is server-local; pin it so the maths is exact
import test from "node:test";
import assert from "node:assert/strict";
import { openDb } from "./db.js";
import { buildApp } from "./app.js";
import { createPairingCode } from "./auth.js";
import { _setStatfsForTest } from "./settings.js";
import { MISSED_AFTER_MS, nextRunAfter, tickSchedules, validateFields, type Deps, type Spec } from "./schedule.js";

const D = (s: string) => new Date(s);
const iso = (d: Date | null) => (d ? d.toISOString() : null);

// ---- timetable maths -------------------------------------------------------------------------

test("daily: later today, else tomorrow; strictly after `after`", () => {
  const spec = { kind: "daily", time: "09:00", days: null } as const;
  assert.equal(iso(nextRunAfter(spec, D("2026-10-07T08:00:00Z"))), "2026-10-07T09:00:00.000Z");
  assert.equal(iso(nextRunAfter(spec, D("2026-10-07T09:00:00Z"))), "2026-10-08T09:00:00.000Z", "exactly at the time is already past");
  assert.equal(iso(nextRunAfter(spec, D("2026-10-07T23:59:00Z"))), "2026-10-08T09:00:00.000Z");
});

test("daily with weekdays skips the days not chosen (Sunday = 0)", () => {
  const weekdays: Spec = { kind: "daily", time: "09:00", days: [1, 2, 3, 4, 5] };
  // 2026-10-09 is a Friday; after Friday 10:00 the next weekday run is Monday the 12th.
  assert.equal(D("2026-10-09T10:00:00Z").getDay(), 5);
  assert.equal(iso(nextRunAfter(weekdays, D("2026-10-09T10:00:00Z"))), "2026-10-12T09:00:00.000Z");
  const sunOnly: Spec = { kind: "daily", time: "06:30", days: [0] };
  assert.equal(iso(nextRunAfter(sunOnly, D("2026-10-07T00:00:00Z"))), "2026-10-11T06:30:00.000Z");
  // the same weekday, later today, still counts
  assert.equal(iso(nextRunAfter({ kind: "daily", time: "09:00", days: [3] }, D("2026-10-07T08:00:00Z"))), "2026-10-07T09:00:00.000Z");
});

test("once: the instant if it is still ahead, otherwise null", () => {
  const spec = { kind: "once", runAt: "2026-10-08T12:00:00.000Z" } as const;
  assert.equal(iso(nextRunAfter(spec, D("2026-10-07T00:00:00Z"))), "2026-10-08T12:00:00.000Z");
  assert.equal(nextRunAfter(spec, D("2026-10-08T12:00:00Z")), null);
  assert.equal(nextRunAfter({ kind: "once", runAt: "garbage" }, D("2026-10-07T00:00:00Z")), null);
});

// ---- validation -------------------------------------------------------------------------------------

const GOOD = { title: "Morning check", prompt: "Summarize overnight CI", kind: "daily", time: "09:00" };

test("validateFields accepts a good create body and normalizes days/runAt", () => {
  const r = validateFields({ ...GOOD, days: [5, 1, 3], mode: "plan", model: null }, false);
  assert.ok(r.ok);
  assert.deepEqual((r as any).v.days, [1, 3, 5]);
  const o = validateFields({ title: "t", prompt: "p", kind: "once", runAt: "2026-10-08T12:00:00+02:00" }, false);
  assert.equal((o as any).v.runAt, "2026-10-08T10:00:00.000Z");
});

test("validateFields rejects bad values, unknown keys and missing required fields", () => {
  const bad: [unknown, boolean, RegExp][] = [
    [null, false, /object/], [[], false, /object/], ["x", false, /object/],
    [{ ...GOOD, bogus: 1 }, false, /bogus: unknown field/],
    [{ prompt: "p", kind: "daily" }, false, /title is required/],
    [{ ...GOOD, title: "" }, false, /title/], [{ ...GOOD, title: "x".repeat(121) }, false, /title/],
    [{ ...GOOD, prompt: "   " }, false, /prompt/], [{ ...GOOD, prompt: "x".repeat(8001) }, false, /prompt/], [{ ...GOOD, prompt: "a\0b" }, false, /prompt/],
    [{ ...GOOD, mode: "bypassPermissions" }, false, /mode/], [{ ...GOOD, mode: "" }, false, /mode/],
    [{ ...GOOD, model: "has space" }, false, /model/], [{ ...GOOD, model: 5 }, false, /model/],
    [{ ...GOOD, kind: "hourly" }, false, /kind/],
    [{ ...GOOD, time: "9:00" }, false, /time/], [{ ...GOOD, time: "24:00" }, false, /time/], [{ ...GOOD, time: "09:60" }, false, /time/],
    [{ ...GOOD, days: [] }, false, /days/], [{ ...GOOD, days: [7] }, false, /days/], [{ ...GOOD, days: [1, 1] }, false, /days/], [{ ...GOOD, days: "1" }, false, /days/],
    [{ ...GOOD, runAt: "nope" }, false, /runAt/], [{ ...GOOD, enabled: "yes" }, false, /enabled/],
  ];
  for (const [body, partial, re] of bad) {
    const r = validateFields(body, partial);
    assert.equal(r.ok, false, JSON.stringify(body)?.slice(0, 60));
    assert.match((r as { error: string }).error, re, JSON.stringify(body)?.slice(0, 60));
  }
  assert.equal(validateFields({ enabled: false }, true).ok, true, "a patch needs none of the required fields");
});

// ---- routes -----------------------------------------------------------------------------------------

// NEVER the real SDK in a test: a scheduled run starts a genuine engine session.
function fakeQuery(params: { prompt: AsyncIterable<any>; options: any }) {
  return (async function* () {
    yield { type: "system", subtype: "init", session_id: "fake", model: "m" };
    for await (const _ of params.prompt) yield { type: "result", subtype: "success", total_cost_usd: 0 };
  })();
}

async function setup() {
  const db = openDb(":memory:");
  const started: Record<string, unknown>[] = [];
  const registry = new Map<string, any>();
  const app = await buildApp(db, undefined, registry, fakeQuery);
  const { token } = (await app.inject({ method: "POST", url: "/pair", payload: { code: createPairingCode(db), device_name: "t" } })).json();
  const auth = { authorization: `Bearer ${token}` };
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES ('p','/home/user/vibemobile','vibemobile','unknown')").run();
  const call = (method: string, url: string, payload?: unknown, headers: Record<string, string> = auth) =>
    app.inject({ method: method as any, url, headers, payload: payload as any });
  return { db, app, registry, started, call };
}
process.env.VIBE_PROJECT_ROOTS = "/home/user";

test("create → list: next run computed, zone reported, defaults are safe (ask mode)", async () => {
  const { call } = await setup();
  const r = await call("POST", "/schedules", { projectId: "p", ...GOOD, days: [1, 2, 3, 4, 5] });
  assert.equal(r.statusCode, 201);
  const s = r.json();
  assert.deepEqual([s.mode, s.enabled, s.kind, s.time, s.days, s.projectName], ["ask", true, "daily", "09:00", [1, 2, 3, 4, 5], "vibemobile"]);
  assert.ok(new Date(s.nextRunAt) > new Date(), "next run is ahead");
  const list = (await call("GET", "/schedules")).json();
  assert.equal(list.tz, "UTC");
  assert.equal(list.offsetMin, 0, "the phone needs the server's UTC offset to place one-time runs");
  assert.equal(list.schedules.length, 1);
});

test("create refusals: no project, unknown project 404, project outside the roots 403, past 'once', daily without time, unknown field, cap", async () => {
  const { call, db } = await setup();
  assert.equal((await call("POST", "/schedules", GOOD)).statusCode, 400);
  assert.equal((await call("POST", "/schedules", { projectId: "nope", ...GOOD })).statusCode, 404);
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES ('out','/etc','out','unknown')").run();
  assert.equal((await call("POST", "/schedules", { projectId: "out", ...GOOD })).statusCode, 403);
  const past = await call("POST", "/schedules", { projectId: "p", title: "t", prompt: "p", kind: "once", runAt: "2020-01-01T00:00:00Z" });
  assert.equal(past.statusCode, 400);
  assert.match(past.json().error, /future/);
  assert.equal((await call("POST", "/schedules", { projectId: "p", title: "t", prompt: "p", kind: "daily" })).statusCode, 400);
  assert.equal((await call("POST", "/schedules", { projectId: "p", ...GOOD, extra: 1 })).statusCode, 400);
  for (let i = 0; i < 50; i++) db.prepare("INSERT INTO schedules (id, project_id, title, prompt, kind, time, created_at) VALUES (?,?,?,?,?,?,?)").run(`x${i}`, "p", "t", "p", "daily", "09:00", "2026-01-01T00:00:00Z");
  assert.equal((await call("POST", "/schedules", { projectId: "p", ...GOOD })).statusCode, 429);
});

test("patch: retiming recomputes the next run; disable clears it; enabling a past 'once' is refused; unknown → 404", async () => {
  const { call } = await setup();
  const s = (await call("POST", "/schedules", { projectId: "p", ...GOOD })).json();
  const moved = (await call("PATCH", `/schedules/${s.id}`, { time: "23:30" })).json();
  assert.equal(moved.time, "23:30");
  assert.match(moved.nextRunAt, /T23:30:00\.000Z$/);
  const off = (await call("PATCH", `/schedules/${s.id}`, { enabled: false })).json();
  assert.deepEqual([off.enabled, off.nextRunAt], [false, null]);
  const on = (await call("PATCH", `/schedules/${s.id}`, { enabled: true })).json();
  assert.ok(on.nextRunAt);
  assert.equal((await call("PATCH", `/schedules/${s.id}`, {})).statusCode, 400);
  assert.equal((await call("PATCH", `/schedules/${s.id}`, { mode: "bypassPermissions" })).statusCode, 400);
  assert.equal((await call("PATCH", "/schedules/zzz", { title: "x" })).statusCode, 404);
  const once = (await call("POST", "/schedules", { projectId: "p", title: "t", prompt: "p", kind: "once", runAt: new Date(Date.now() + 3600_000).toISOString() })).json();
  assert.equal((await call("PATCH", `/schedules/${once.id}`, { runAt: "2020-01-01T00:00:00Z" })).statusCode, 400);
});

test("delete is idempotent and audited once; everything needs the token", async () => {
  const { call, db } = await setup();
  const s = (await call("POST", "/schedules", { projectId: "p", ...GOOD })).json();
  assert.equal((await call("DELETE", `/schedules/${s.id}`)).statusCode, 204);
  assert.equal((await call("DELETE", `/schedules/${s.id}`)).statusCode, 204);
  assert.equal((db.prepare("SELECT COUNT(*) n FROM events WHERE kind='schedule.delete'").get() as any).n, 1);
  for (const [m, u] of [["GET", "/schedules"], ["POST", "/schedules"], ["PATCH", "/schedules/x"], ["DELETE", "/schedules/x"], ["POST", "/schedules/x/run"]]) {
    assert.equal((await call(m, u, {}, {})).statusCode, 401, `${m} ${u}`);
  }
});

// ---- ticking ------------------------------------------------------------------------------------------

function ticker(at: string) {
  const db = openDb(":memory:");
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES ('p','/home/user/vibemobile','vibemobile','unknown')").run();
  const started: Record<string, unknown>[] = [];
  const busy = new Set<string>();
  let now = D(at);
  const deps: Deps = { now: () => now, start: (row) => void started.push(row), busy: (id) => busy.has(id) };
  const add = (over: Record<string, unknown> = {}) => {
    const r = { id: "sch1", project_id: "p", title: "Morning check", prompt: "Summarize CI", mode: "ask", model: null, kind: "daily", time: "09:00", days: null, run_at: null, enabled: 1, next_run_at: "2026-10-07T09:00:00.000Z", ...over };
    db.prepare("INSERT INTO schedules (id, project_id, title, prompt, mode, model, kind, time, days, run_at, enabled, next_run_at, created_at) VALUES (@id,@project_id,@title,@prompt,@mode,@model,@kind,@time,@days,@run_at,@enabled,@next_run_at,'2026-01-01T00:00:00Z')").run(r);
  };
  const row = (id = "sch1") => db.prepare("SELECT * FROM schedules WHERE id = ?").get(id) as any;
  return { db, deps, started, busy, add, row, setNow: (s: string) => (now = D(s)) };
}

test("a due schedule starts an ordinary session in ask mode, primed with its prompt, and moves to tomorrow", () => {
  const t = ticker("2026-10-07T09:00:20Z");
  t.add();
  tickSchedules(t.db, t.deps);
  assert.equal(t.started.length, 1);
  const s = t.started[0] as any;
  assert.deepEqual([s.kind, s.status, s.mode, s.initial_prompt, s.title, s.project_id], ["claude", "live", "ask", "Summarize CI", "⏰ Morning check", "p"]);
  const r = t.row();
  assert.deepEqual([r.last_status, r.last_session_id, r.next_run_at, r.enabled], ["started", s.id, "2026-10-08T09:00:00.000Z", 1]);
  assert.ok(t.db.prepare("SELECT 1 FROM events WHERE kind='schedule.run'").get());
});

test("not yet due / disabled / already advanced → nothing runs; a second tick doesn't double-fire", () => {
  const t = ticker("2026-10-07T08:59:00Z");
  t.add();
  t.add({ id: "off", enabled: 0 });
  tickSchedules(t.db, t.deps);
  assert.equal(t.started.length, 0);
  t.setNow("2026-10-07T09:00:30Z");
  tickSchedules(t.db, t.deps);
  tickSchedules(t.db, t.deps);
  assert.equal(t.started.length, 1, "next_run_at moved on, so the second tick finds nothing due");
});

test("a 'once' schedule runs once and switches itself off", () => {
  const t = ticker("2026-10-07T12:00:05Z");
  t.add({ kind: "once", time: null, run_at: "2026-10-07T12:00:00.000Z", next_run_at: "2026-10-07T12:00:00.000Z" });
  tickSchedules(t.db, t.deps);
  const r = t.row();
  assert.deepEqual([t.started.length, r.enabled, r.next_run_at, r.last_status], [1, 0, null, "started"]);
});

test("a run missed by more than 2 h (daemon was down) is recorded as missed — NOT fired late", () => {
  const t = ticker("2026-10-07T09:00:00Z");
  t.add({ next_run_at: new Date(D("2026-10-07T09:00:00Z").getTime() - MISSED_AFTER_MS - 60_000).toISOString() });
  tickSchedules(t.db, t.deps);
  const r = t.row();
  assert.equal(t.started.length, 0);
  assert.equal(r.last_status, "missed");
  assert.ok(D(r.next_run_at) > D("2026-10-07T09:00:00Z"), "rescheduled for the next slot");
  assert.ok(t.db.prepare("SELECT 1 FROM events WHERE kind='schedule.missed'").get());
});

test("a run just inside the grace window still fires (a slow restart)", () => {
  const t = ticker("2026-10-07T10:30:00Z");
  t.add({ next_run_at: "2026-10-07T09:00:00.000Z" }); // 1.5 h late
  tickSchedules(t.db, t.deps);
  assert.equal(t.started.length, 1);
});

test("one run at a time: a still-busy previous run skips this slot but the schedule carries on", () => {
  const t = ticker("2026-10-07T09:00:05Z");
  t.add();
  tickSchedules(t.db, t.deps);
  const first = t.row().last_session_id;
  t.busy.add(first);
  t.setNow("2026-10-08T09:00:05Z");
  tickSchedules(t.db, t.deps);
  const r = t.row();
  assert.equal(t.started.length, 1, "no second session while the first is working");
  assert.match(r.last_status, /^skipped: the previous run is still going/);
  assert.equal(r.next_run_at, "2026-10-09T09:00:00.000Z");
});

test("the live-session cap makes a run wait and retry on the next tick instead of being lost", () => {
  const t = ticker("2026-10-07T09:00:05Z");
  t.add();
  process.env.VIBE_MAX_CLAUDE = "1";
  try {
    t.db.prepare("INSERT INTO sessions (id, project_id, kind, status, created_at) VALUES ('busy','p','claude','live','2026-01-01T00:00:00Z')").run();
    tickSchedules(t.db, t.deps);
    assert.equal(t.started.length, 0);
    assert.match(t.row().last_status, /^waiting: too many live sessions/);
    assert.equal(t.row().next_run_at, "2026-10-07T09:00:00.000Z", "still due, so it is retried");
    t.db.prepare("DELETE FROM sessions WHERE id='busy'").run();
    t.setNow("2026-10-07T09:00:40Z");
    tickSchedules(t.db, t.deps);
    assert.equal(t.started.length, 1);
  } finally {
    delete process.env.VIBE_MAX_CLAUDE;
  }
});

test("the free-space guard applies: low disk → waits", () => {
  const t = ticker("2026-10-07T09:00:05Z");
  t.add();
  try {
    _setStatfsForTest(() => ({ free: 1e9 }));
    tickSchedules(t.db, t.deps);
    assert.equal(t.started.length, 0);
    assert.match(t.row().last_status, /^waiting: low disk space/);
  } finally {
    _setStatfsForTest(null);
  }
});

test("a vanished project fails the run (no retry loop) and is audited as skipped", () => {
  const t = ticker("2026-10-07T09:00:05Z");
  t.add();
  t.db.pragma("foreign_keys = OFF");
  t.db.prepare("DELETE FROM projects WHERE id='p'").run();
  tickSchedules(t.db, t.deps);
  assert.match(t.row().last_status, /^failed: project is gone/);
  assert.equal(t.started.length, 0);
});

test("if starting the engine throws, the half-made session row is removed and the failure recorded", () => {
  const t = ticker("2026-10-07T09:00:05Z");
  t.add();
  t.deps.start = () => {
    throw new Error("sdk exploded");
  };
  tickSchedules(t.db, t.deps);
  assert.equal((t.db.prepare("SELECT COUNT(*) n FROM sessions").get() as any).n, 0);
  assert.match(t.row().last_status, /^failed: sdk exploded/);
});

test("a schedule can run in auto mode only because the user asked for it explicitly, and says so in the audit", () => {
  const t = ticker("2026-10-07T09:00:05Z");
  t.add({ mode: "auto" });
  tickSchedules(t.db, t.deps);
  assert.equal((t.started[0] as any).mode, "auto");
  assert.match((t.db.prepare("SELECT detail FROM events WHERE kind='schedule.run'").get() as any).detail, /:auto$/);
});

test("POST /schedules/:id/run starts a session now, leaves the timetable alone, and reports why when it can't", async () => {
  const { call, db } = await setup();
  const s = (await call("POST", "/schedules", { projectId: "p", ...GOOD })).json();
  const before = (db.prepare("SELECT next_run_at FROM schedules WHERE id=?").get(s.id) as any).next_run_at;
  process.env.VIBE_MAX_CLAUDE = "0";
  try {
    const blocked = await call("POST", `/schedules/${s.id}/run`);
    assert.equal(blocked.statusCode, 429);
    assert.match(blocked.json().error, /too many live sessions/);
  } finally {
    delete process.env.VIBE_MAX_CLAUDE;
  }
  assert.equal((await call("POST", "/schedules/nope/run")).statusCode, 404);
  // success path needs a startable engine: scripted via the injected start
  const { call: call2, db: db2, registry: registry2 } = await setup();
  const s2 = (await call2("POST", "/schedules", { projectId: "p", ...GOOD, mode: "plan" })).json();
  const r = await call2("POST", `/schedules/${s2.id}/run`);
  assert.equal(r.statusCode, 201);
  assert.ok([...registry2.keys()].includes(r.json().sessionId), "the engine was started (with the fake SDK)");
  const sess = db2.prepare("SELECT * FROM sessions WHERE id = ?").get(r.json().sessionId) as any;
  // Starting the engine consumes initial_prompt (queues it as the first turn), so the proof
  // the prompt was delivered is the stored user message.
  assert.deepEqual([sess.mode, sess.title, sess.initial_prompt], ["plan", "⏰ Morning check", null]);
  assert.equal((db2.prepare("SELECT content FROM messages WHERE session_id = ? AND role = 'user'").get(sess.id) as any).content, GOOD.prompt);
  assert.equal((db2.prepare("SELECT next_run_at FROM schedules WHERE id=?").get(s2.id) as any).next_run_at !== null, true);
  assert.equal((db.prepare("SELECT next_run_at FROM schedules WHERE id=?").get(s.id) as any).next_run_at, before);
});
