// Continue after the usage limit (proposal 67): the pure decision, the tick's bounds and the PATCH field.

import test from "node:test";
import assert from "node:assert/strict";
import { openDb } from "./db.js";
import { buildApp } from "./app.js";
import { createPairingCode } from "./auth.js";
import { _setStatfsForTest } from "./settings.js";
import { CONTINUE_PROMPT, planContinuation, tickContinuations, type Deps } from "./limit.js";
import type { PushType } from "./push.js";

const NOW = Date.parse("2026-11-04T02:00:00Z");
const resets = (afterS: number) => Math.floor(NOW / 1000) + afterS;
const ON = { continue_after_limit: 1 };
const rejected = (over: Record<string, unknown> = {}) => ({ status: "rejected", rateLimitType: "five_hour", resetsAt: resets(3600), ...over });

// ---- planContinuation ---------------------------------------------------------------------

test("five_hour rejected: continue_at lands 60-180 s after the reset", () => {
  const lo = planContinuation(rejected(), ON, NOW, () => 0)!;
  const hi = planContinuation(rejected(), ON, NOW, () => 0.999999)!;
  assert.equal(Date.parse(lo), resets(3600) * 1000 + 60_000);
  assert.equal(Date.parse(hi), resets(3600) * 1000 + 179_000);
});

test("weekly, far-off reset, toggle off, allowed, missing resetsAt: no continuation", () => {
  assert.equal(planContinuation(rejected({ rateLimitType: "seven_day" }), ON, NOW), null);
  assert.equal(planContinuation(rejected({ resetsAt: resets(24 * 3600 + 1) }), ON, NOW), null);
  assert.equal(planContinuation(rejected(), { continue_after_limit: 0 }, NOW), null);
  assert.equal(planContinuation(rejected({ status: "allowed" }), ON, NOW), null);
  assert.equal(planContinuation(rejected({ status: "allowed_warning" }), ON, NOW), null);
  assert.equal(planContinuation(rejected({ resetsAt: undefined }), ON, NOW), null);
  assert.equal(planContinuation(rejected(), undefined, NOW), null);
});

// ---- tick -----------------------------------------------------------------------------------

function ticker() {
  const db = openDb(":memory:");
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES ('p','/home/user/vibemobile','vibemobile','unknown')").run();
  const sent: { id: string; text: string }[] = [];
  const pushes: [PushType, string][] = [];
  const busy = new Set<string>();
  const deps: Deps = {
    now: () => new Date(NOW),
    send: (row, text) => void sent.push({ id: row.id as string, text }),
    busy: (id) => busy.has(id),
    push: (type, id) => void pushes.push([type, id]),
  };
  const add = (id: string, over: Record<string, unknown> = {}) => {
    db.prepare("INSERT INTO sessions (id, project_id, kind, status, created_at) VALUES (?, 'p', 'claude', 'live', '2026-01-01T00:00:00Z')").run(id);
    const r = { continue_after_limit: 1, continue_at: new Date(NOW - 1000).toISOString(), continue_count: 0, ...over };
    db.prepare("UPDATE sessions SET continue_after_limit=@continue_after_limit, continue_at=@continue_at, continue_count=@continue_count WHERE id=@id").run({ ...r, id });
  };
  const row = (id: string) => db.prepare("SELECT * FROM sessions WHERE id = ?").get(id) as any;
  return { db, deps, sent, pushes, busy, add, row };
}

test("a due continuation sends the fixed prompt, bumps the count and clears the wait", () => {
  _setStatfsForTest(() => ({ free: 1e12 }));
  const t = ticker();
  t.add("s1", { continue_count: 1 });
  try {
    tickContinuations(t.db, t.deps);
  } finally {
    _setStatfsForTest(null);
  }
  assert.deepEqual(t.sent, [{ id: "s1", text: CONTINUE_PROMPT }]);
  assert.deepEqual([t.row("s1").continue_count, t.row("s1").continue_at], [2, null]);
  assert.deepEqual(t.pushes, [["limit_continued", "s1"]]);
  assert.ok(t.db.prepare("SELECT 1 FROM events WHERE kind='session.limit_continued'").get());
  tickContinuations(t.db, t.deps);
  assert.equal(t.sent.length, 1, "cleared, so the next tick finds nothing");
});

test("not yet due or toggled off: nothing happens", () => {
  const t = ticker();
  t.add("later", { continue_at: new Date(NOW + 60_000).toISOString() });
  t.add("off", { continue_after_limit: 0 });
  tickContinuations(t.db, t.deps);
  assert.equal(t.sent.length, 0);
  assert.equal(t.pushes.length, 0);
});

test("the 4th continuation in a row gives up", () => {
  const t = ticker();
  t.add("s1", { continue_count: 3 });
  tickContinuations(t.db, t.deps);
  assert.equal(t.sent.length, 0);
  assert.equal(t.row("s1").continue_at, null);
  assert.deepEqual(t.pushes, [["limit_gave_up", "s1"]]);
  assert.ok(t.db.prepare("SELECT 1 FROM events WHERE kind='session.limit_gave_up'").get());
});

test("low disk: the wait is kept and retried on a later tick", () => {
  const t = ticker();
  t.add("s1");
  try {
    _setStatfsForTest(() => ({ free: 1e6 }));
    tickContinuations(t.db, t.deps);
  } finally {
    _setStatfsForTest(null);
  }
  assert.equal(t.sent.length, 0);
  assert.notEqual(t.row("s1").continue_at, null);
  assert.equal(t.pushes.length, 0);
});

test("a busy session is skipped and its wait cleared", () => {
  const t = ticker();
  t.add("s1");
  t.busy.add("s1");
  tickContinuations(t.db, t.deps);
  assert.equal(t.sent.length, 0);
  assert.deepEqual([t.row("s1").continue_at, t.row("s1").continue_count], [null, 0]);
  assert.equal(t.pushes.length, 0);
});

test("a failing send is logged, keeps the wait for a retry and does not stop the rest", () => {
  const t = ticker();
  t.add("bad");
  t.add("good");
  t.deps.send = (row, text) => {
    if (row.id === "bad") throw new Error("boom");
    t.sent.push({ id: row.id as string, text });
  };
  const err = console.error;
  console.error = () => {};
  try {
    assert.doesNotThrow(() => tickContinuations(t.db, t.deps));
  } finally {
    console.error = err;
  }
  assert.deepEqual(t.sent.map((s) => s.id), ["good"]);
  assert.notEqual(t.row("bad").continue_at, null);
  assert.equal(t.row("bad").continue_count, 0);
});

// ---- PATCH /sessions/:id ----------------------------------------------------------------------

test("PATCH continueAfterLimit validates, audits, and the session reads back camelCase", async () => {
  const db = openDb(":memory:");
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES ('p','/home/user/vibemobile','vibemobile','unknown')").run();
  db.prepare("INSERT INTO sessions (id, project_id, kind, status, created_at) VALUES ('s1','p','claude','live','2026-01-01T00:00:00Z')").run();
  const app = await buildApp(db, undefined, new Map());
  const code = createPairingCode(db);
  const paired = await app.inject({ method: "POST", url: "/pair", payload: { code, device_name: "t" } });
  const headers = { authorization: `Bearer ${paired.json().token}` };
  const patch = (payload: unknown) => app.inject({ method: "PATCH", url: "/sessions/s1", headers, payload: payload as any });

  assert.equal((await patch({ continueAfterLimit: "yes" })).statusCode, 400);
  const on = await patch({ continueAfterLimit: true });
  assert.equal(on.statusCode, 200);
  assert.deepEqual([on.json().continueAfterLimit, on.json().continueAt], [true, null]);
  assert.ok(db.prepare("SELECT 1 FROM events WHERE kind='session.continue_after_limit'").get());
  const got = await app.inject({ method: "GET", url: "/sessions/s1", headers });
  assert.equal(got.json().continueAfterLimit, true);
  assert.equal((await patch({ continueAfterLimit: false })).json().continueAfterLimit, false);
  await app.close();
});
