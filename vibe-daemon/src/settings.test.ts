// Settings + session rules + disk guard (ADR 0026).

import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { openDb } from "./db.js";
import { buildApp } from "./app.js";
import { createPairingCode } from "./auth.js";
import { ClaudeSession } from "./claude.js";
import { NativeSession } from "./native.js";
import { computeAlerts } from "./system.js";
import {
  DEFAULT_RULES, SETTINGS, _setStatfsForTest, applySettings, diskGuard, getSetting, rulesForPrompt, settingsView,
} from "./settings.js";

const ROOT = mkdtempSync(join(tmpdir(), "vibe-set-"));
process.env.VIBE_PROJECT_ROOTS = ROOT;
process.env.OPENAI_API_KEY ??= "sk-test";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
async function waitFor(fn: () => boolean, ms = 1500) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) {
    if (fn()) return;
    await sleep(5);
  }
  throw new Error("timed out");
}
const fakeWs = () => {
  const frames: any[] = [];
  return { OPEN: 1, readyState: 1, frames, send: (s: string) => frames.push(JSON.parse(s)), on() {}, ping() {}, terminate() {}, close() {} } as any;
};

async function setup() {
  const db = openDb(":memory:");
  const app = await buildApp(db);
  const { token } = (await app.inject({ method: "POST", url: "/pair", payload: { code: createPairingCode(db), device_name: "Pixel" } })).json();
  const auth = { authorization: `Bearer ${token}` };
  const put = (values: unknown, headers: Record<string, string> = auth) =>
    app.inject({ method: "PUT", url: "/settings", headers, payload: { values } as any });
  return { db, app, auth, put };
}

// ---- defaults + validation ---------------------------------------------------------------

test("defaults: rules on with the storage text, alert at 90%, 5 GB free guard", () => {
  const db = openDb(":memory:");
  assert.equal(getSetting(db, "rules.enabled"), true);
  assert.equal(getSetting(db, "rules.text"), DEFAULT_RULES);
  assert.equal(getSetting(db, "disk.alert_percent"), 90);
  assert.equal(getSetting(db, "disk.min_free_gb"), 5);
  assert.match(DEFAULT_RULES, /\/data\/cache/);
  assert.match(DEFAULT_RULES, /\/mnt\/sdd1/);
  assert.ok(settingsView(db).every((s) => s.isDefault));
});

test("applySettings is all-or-nothing and rejects unknown keys, wrong types and out-of-range values", () => {
  const db = openDb(":memory:");
  const bad: [Record<string, unknown>, string][] = [
    [{ "nope.key": 1 }, "nope.key"],
    [{ "rules.enabled": "yes" }, "rules.enabled"],
    [{ "disk.alert_percent": 49 }, "disk.alert_percent"],
    [{ "disk.alert_percent": 100 }, "disk.alert_percent"],
    [{ "disk.alert_percent": 90.5 }, "disk.alert_percent"],
    [{ "disk.alert_percent": "90" }, "disk.alert_percent"],
    [{ "disk.alert_percent": NaN }, "disk.alert_percent"],
    [{ "disk.min_free_gb": -1 }, "disk.min_free_gb"],
    [{ "disk.min_free_gb": 501 }, "disk.min_free_gb"],
    [{ "rules.text": "x".repeat(4001) }, "rules.text"],
    [{ "rules.text": "a\0b" }, "rules.text"],
    [{ "rules.text": 5 }, "rules.text"],
    // As they arrive over the wire: JSON.parse makes these OWN keys (a `{__proto__: 1}`
    // literal would silently set the prototype instead). Both used to be accepted.
    [JSON.parse('{"__proto__": 1}'), "__proto__"],
    [JSON.parse('{"constructor": 1}'), "constructor"],
    [JSON.parse('{"toString": true}'), "toString"],
    [JSON.parse('{"hasOwnProperty": null}'), "hasOwnProperty"],
  ];
  for (const [updates, key] of bad) {
    const r = applySettings(db, updates, "d1");
    assert.equal(r.ok, false, JSON.stringify(updates).slice(0, 40));
    assert.equal((r as { key: string }).key, key);
  }
  // a valid key alongside an invalid one changes nothing
  const r = applySettings(db, { "disk.alert_percent": 80, "disk.min_free_gb": 9999 }, "d1");
  assert.equal(r.ok, false);
  assert.equal(getSetting(db, "disk.alert_percent"), 90, "all-or-nothing");
});

test("a valid update sticks, null resets to default, and a hand-edited bad row falls back to the default", () => {
  const db = openDb(":memory:");
  assert.equal(applySettings(db, { "disk.alert_percent": 80, "rules.enabled": false, "disk.min_free_gb": 12.5 }, "d1").ok, true);
  assert.equal(getSetting(db, "disk.alert_percent"), 80);
  assert.equal(getSetting(db, "rules.enabled"), false);
  assert.equal(getSetting(db, "disk.min_free_gb"), 12.5);
  assert.equal(applySettings(db, { "disk.alert_percent": null }, "d1").ok, true);
  assert.equal(getSetting(db, "disk.alert_percent"), 90);
  db.prepare("UPDATE settings SET value = ? WHERE key = 'disk.min_free_gb'").run('"garbage"');
  assert.equal(getSetting(db, "disk.min_free_gb"), 5, "a poisoned row never reaches a consumer");
  db.prepare("UPDATE settings SET value = ? WHERE key = 'disk.min_free_gb'").run("{not json");
  assert.equal(getSetting(db, "disk.min_free_gb"), 5);
});

test("audit records key names and the rules LENGTH, never the rules text", () => {
  const db = openDb(":memory:");
  applySettings(db, { "rules.text": "SECRET-ISH POLICY TEXT", "disk.alert_percent": 85 }, "dev9");
  const e = db.prepare("SELECT kind, device_id, detail FROM events WHERE kind='settings.update'").get() as any;
  assert.equal(e.device_id, "dev9");
  assert.match(e.detail, /rules\.text\(22 chars\)/);
  assert.match(e.detail, /disk\.alert_percent=85/);
  assert.doesNotMatch(e.detail, /POLICY/);
});

// ---- the API -------------------------------------------------------------------------------

test("GET /settings lists every key with default/min/max; PUT updates and returns the new view", async () => {
  const { app, auth, put } = await setup();
  const g = (await app.inject({ method: "GET", url: "/settings", headers: auth })).json();
  assert.deepEqual(g.settings.map((s: any) => s.key).sort(), Object.keys(SETTINGS).sort());
  const alert = g.settings.find((s: any) => s.key === "disk.alert_percent");
  assert.deepEqual([alert.value, alert.default, alert.min, alert.max, alert.isDefault], [90, 90, 50, 99, true]);

  const r = await put({ "disk.alert_percent": 75 });
  assert.equal(r.statusCode, 200);
  const after = r.json().settings.find((s: any) => s.key === "disk.alert_percent");
  assert.deepEqual([after.value, after.isDefault], [75, false]);
});

test("PUT /settings: bad body or bad value is 400 with the key named; nothing changes", async () => {
  const { put, app, auth } = await setup();
  for (const body of [undefined, null, [], {}, "x"]) assert.equal((await put(body)).statusCode, 400, JSON.stringify(body));
  const r = await put({ "disk.alert_percent": 10 });
  assert.equal(r.statusCode, 400);
  assert.match(r.json().error, /^disk\.alert_percent: must be between 50 and 99/);
  const g = (await app.inject({ method: "GET", url: "/settings", headers: auth })).json();
  assert.ok(g.settings.every((s: any) => s.isDefault));
});

test("settings routes need the bearer token", async () => {
  const { app, put } = await setup();
  assert.equal((await app.inject({ method: "GET", url: "/settings" })).statusCode, 401);
  assert.equal((await put({ "disk.alert_percent": 80 }, {})).statusCode, 401);
});

// ---- rules reach the models --------------------------------------------------------------------

test("rulesForPrompt: on by default, off when disabled or blank, custom text used verbatim (trimmed)", () => {
  const db = openDb(":memory:");
  assert.equal(rulesForPrompt(db), DEFAULT_RULES.trim());
  applySettings(db, { "rules.text": "  Be nice.  " }, null);
  assert.equal(rulesForPrompt(db), "Be nice.");
  applySettings(db, { "rules.text": "   " }, null);
  assert.equal(rulesForPrompt(db), null, "blank text = nothing to append");
  applySettings(db, { "rules.text": null, "rules.enabled": false }, null);
  assert.equal(rulesForPrompt(db), null);
});

function claudeSession(db: ReturnType<typeof openDb>) {
  const seen: { options?: any } = {};
  const queryFn = (params: { prompt: AsyncIterable<any>; options: any }) => {
    if (!params.options?.canUseTool) return (async function* () {})(); // titler
    seen.options = params.options;
    return (async function* () {
      yield { type: "system", subtype: "init", session_id: "c", model: "m" };
      for await (const _ of params.prompt) yield { type: "result", subtype: "success", total_cost_usd: 0 };
    })();
  };
  db.prepare("INSERT OR IGNORE INTO projects (id, path, name, type) VALUES ('p','/tmp','p','unknown')").run();
  db.prepare("INSERT INTO sessions (id, project_id, kind, status, created_at) VALUES ('s','p','claude','live',?)").run(new Date().toISOString());
  const s = new ClaudeSession(db, "s", "/tmp", queryFn as any);
  s.attach(fakeWs());
  s.start();
  return seen;
}

test("every Claude session gets the rules appended to the Claude Code preset (so CLAUDE.md still loads)", () => {
  const db = openDb(":memory:");
  const seen = claudeSession(db);
  assert.deepEqual(seen.options.systemPrompt, { type: "preset", preset: "claude_code", append: DEFAULT_RULES.trim() });
});

test("rules off → no systemPrompt override at all (today's behaviour); custom text is what is sent", () => {
  const off = openDb(":memory:");
  applySettings(off, { "rules.enabled": false }, null);
  assert.equal(claudeSession(off).options.systemPrompt, undefined);
  const custom = openDb(":memory:");
  applySettings(custom, { "rules.text": "Only use /data." }, null);
  assert.equal(claudeSession(custom).options.systemPrompt.append, "Only use /data.");
});

test("a setting changed mid-life applies to the NEXT session start, not a running one", () => {
  const db = openDb(":memory:");
  const first = claudeSession(db);
  applySettings(db, { "rules.text": "Changed." }, null);
  assert.equal(first.options.systemPrompt.append, DEFAULT_RULES.trim(), "the running session keeps what it started with");
  db.prepare("DELETE FROM sessions").run();
  assert.equal(claudeSession(db).options.systemPrompt.append, "Changed.");
});

test("native (non-Claude) models get the same rules in their system prompt", async () => {
  const db = openDb(":memory:");
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES ('p1','/tmp','p','unknown')").run();
  db.prepare("INSERT INTO sessions (id, project_id, kind, status, created_at, model) VALUES ('s1','p1','claude','live',?,?)").run(new Date().toISOString(), "gpt-4o");
  const systems: string[] = [];
  const streamText = (args: any) => {
    systems.push(args.system);
    return {
      fullStream: (async function* () { yield { type: "finish", finishReason: "stop", totalUsage: { inputTokens: 1, outputTokens: 1 } }; })(),
      response: Promise.resolve({ messages: [{ role: "assistant", content: "ok" }] }),
    };
  };
  const ws = fakeWs();
  const s = new NativeSession(db, "s1", "/tmp", "openai:gpt-4o", streamText as any);
  s.attach(ws);
  s.pushUser("hi");
  await waitFor(() => ws.frames.some((f: any) => f.t === "result"));
  assert.match(systems[0], /coding assistant operating in the project directory/);
  assert.match(systems[0], /Storage rules \(VibeMobile\)/);
  applySettings(db, { "rules.enabled": false }, null);
  s.pushUser("again");
  await waitFor(() => ws.frames.filter((f: any) => f.t === "result").length === 2);
  assert.doesNotMatch(systems[1], /Storage rules/, "off means off, per turn");
});

// ---- disk alert threshold ----------------------------------------------------------------------

test("computeAlerts honours the configurable disk threshold", () => {
  const base = { mem: { total: 100, available: 90, swapTotal: 0, swapFree: 0 }, gpus: [] as any[] };
  const disks = [{ path: "/", total: 1000, free: 120 }]; // 88% used
  assert.deepEqual(computeAlerts({ ...base, disks }).map((a) => a.key), [], "88% < default 90%");
  assert.deepEqual(computeAlerts({ ...base, disks }, 85).map((a) => a.key), ["disk:/"], "88% > 85%");
  assert.deepEqual(computeAlerts({ ...base, disks }, 99).map((a) => a.key), []);
});

// ---- disk guard ---------------------------------------------------------------------------------

test("diskGuard: blocks below the minimum, passes above, 0 disables, unreadable fs fails open", () => {
  const db = openDb(":memory:");
  try {
    _setStatfsForTest(() => ({ free: 3e9 }));
    const low = diskGuard(db, "/x");
    assert.equal(low.ok, false);
    assert.match((low as { message: string }).message, /Only 3\.0 GB free .*minimum 5 GB/);
    _setStatfsForTest(() => ({ free: 50e9 }));
    assert.equal(diskGuard(db, "/x").ok, true);
    applySettings(db, { "disk.min_free_gb": 0 }, null);
    _setStatfsForTest(() => ({ free: 0 }));
    assert.equal(diskGuard(db, "/x").ok, true, "0 = guard off");
    applySettings(db, { "disk.min_free_gb": 5 }, null);
    _setStatfsForTest(() => null);
    assert.equal(diskGuard(db, "/x").ok, true, "can't read the filesystem ⇒ don't block work");
  } finally {
    _setStatfsForTest(null);
  }
});

test("POST /sessions and POST /projects are refused with 507 on a full disk, and nothing is created", async () => {
  const { app, auth, db } = await setup();
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES ('p',?, 'p','unknown')").run(ROOT);
  try {
    _setStatfsForTest(() => ({ free: 1e9 }));
    const s = await app.inject({ method: "POST", url: "/sessions", headers: auth, payload: { project_id: "p", kind: "claude" } });
    assert.equal(s.statusCode, 507);
    assert.match(s.json().error, /Only 1\.0 GB free/);
    assert.equal((db.prepare("SELECT COUNT(*) n FROM sessions").get() as any).n, 0);
    assert.ok(db.prepare("SELECT 1 FROM events WHERE kind='session.disk_guard'").get());

    const p = await app.inject({ method: "POST", url: "/projects", headers: auth, payload: { name: "newproj", git: false } });
    assert.equal(p.statusCode, 507);

    _setStatfsForTest(() => ({ free: 100e9 }));
    assert.equal((await app.inject({ method: "POST", url: "/sessions", headers: auth, payload: { project_id: "p", kind: "claude" } })).statusCode, 201);
  } finally {
    _setStatfsForTest(null);
  }
});
