// spend.ts (ADR 0017) — the usage ledger, GET /spend aggregates, and both engines
// writing to it (fake SDK / fake AI SDK, no spend).

import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { openDb, type DB } from "./db.js";
import { buildApp } from "./app.js";
import { createPairingCode } from "./auth.js";
import { recordUsage, recordCumulative, cumulativeCostDelta, counterDelta, migrateLedgerToDeltas } from "./spend.js";
import { ClaudeSession } from "./claude.js";
import { NativeSession } from "./native.js";
import type { Tmux } from "./tmux.js";

process.env.OPENAI_API_KEY ??= "sk-test";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
async function waitFor(fn: () => boolean, ms = 1500) {
  const end = Date.now() + ms;
  while (!fn()) {
    if (Date.now() > end) throw new Error("timed out");
    await sleep(5);
  }
}
const fakeWs = () =>
  ({ OPEN: 1, readyState: 1, frames: [] as any[], send(s: string) { this.frames.push(JSON.parse(s)); }, on() {}, close() {} }) as any;

function seed(db: DB) {
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES (?,?,?,?)").run("p1", "/tmp/a", "alpha", "unknown");
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES (?,?,?,?)").run("p2", "/tmp/b", "beta", "unknown");
  const now = new Date().toISOString();
  for (const [id, p] of [["s1", "p1"], ["s2", "p2"]]) {
    db.prepare("INSERT INTO sessions (id, project_id, kind, status, created_at) VALUES (?,?,?,?,?)").run(id, p, "claude", "live", now);
  }
}

async function setup() {
  const db = openDb(":memory:");
  seed(db);
  const tmux = {} as Tmux;
  const app = await buildApp(db, tmux, new Map());
  const { token } = (
    await app.inject({ method: "POST", url: "/pair", payload: { code: createPairingCode(db), device_name: "t" } })
  ).json();
  return { db, app, auth: { authorization: `Bearer ${token}` } };
}

test("GET /spend groups the ledger by model / project / day, with totals", async () => {
  const { db, app, auth } = await setup();
  recordUsage(db, { sessionId: "s1", provider: "anthropic", model: "claude-opus-4-8", input: 100, output: 50, cacheRead: 900, cacheWrite: 10, cost: 0.2 });
  recordUsage(db, { sessionId: "s1", provider: "anthropic", model: "claude-haiku-4-5", input: 10, output: 5, cost: 0.01 });
  recordUsage(db, { sessionId: "s2", provider: "openai", model: "openai:gpt-5", input: 40, output: 20, cost: 0.05 });
  // Outside the window: backdate one row 40 days.
  recordUsage(db, { sessionId: "s2", provider: "openai", model: "openai:gpt-5", input: 1, output: 1, cost: 9 });
  db.prepare("UPDATE usage_events SET ts = ? WHERE cost_usd = 9").run(new Date(Date.now() - 40 * 86_400_000).toISOString());

  const byModel = (await app.inject({ method: "GET", url: "/spend?group=model&days=30", headers: auth })).json();
  assert.equal(byModel.totals.turns, 3);
  assert.equal(byModel.totals.cacheRead, 900);
  assert.ok(Math.abs(byModel.totals.cost - 0.26) < 1e-9);
  assert.deepEqual(byModel.rows.map((r: any) => r.key), ["claude-opus-4-8", "openai:gpt-5", "claude-haiku-4-5"]); // cost desc

  const byProject = (await app.inject({ method: "GET", url: "/spend?group=project", headers: auth })).json();
  assert.deepEqual(byProject.rows.map((r: any) => [r.key, r.label, r.turns]), [["p1", "alpha", 2], ["p2", "beta", 1]]);
  assert.ok(byProject.rows.every((r: any) => !("path" in r)), "absolute paths stay server-side");

  const byDay = (await app.inject({ method: "GET", url: "/spend?group=day&days=60", headers: auth })).json();
  assert.equal(byDay.rows.length, 2);
  assert.ok(byDay.rows[0].key < byDay.rows[1].key, "days ascending");

  const empty = (await app.inject({ method: "GET", url: "/spend?days=1", headers: auth })).json();
  assert.equal(empty.totals.turns, 3);
});

test("GET /spend: bad group → 400; unauthenticated → 401; empty ledger → zero totals", async () => {
  const { app, auth } = await setup();
  assert.equal((await app.inject({ method: "GET", url: "/spend?group=u.ts;DROP", headers: auth })).statusCode, 400);
  assert.equal((await app.inject({ method: "GET", url: "/spend" })).statusCode, 401);
  const r = (await app.inject({ method: "GET", url: "/spend", headers: auth })).json();
  assert.deepEqual(r.totals, { turns: 0, input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0 });
  assert.deepEqual(r.rows, []);
});

test("Claude turns record one ledger row per model in modelUsage", async () => {
  const db = openDb(":memory:");
  seed(db);
  const query = ({ prompt }: any) =>
    (async function* () {
      yield { type: "system", subtype: "init", session_id: "c1", model: "claude-x" };
      await prompt[Symbol.asyncIterator]().next();
      yield {
        type: "result",
        subtype: "success",
        total_cost_usd: 0.3,
        modelUsage: {
          "claude-opus-4-8": { inputTokens: 12, outputTokens: 34, cacheReadInputTokens: 5000, cacheCreationInputTokens: 200, costUSD: 0.29 },
          "claude-haiku-4-5": { inputTokens: 3, outputTokens: 4, cacheReadInputTokens: 0, cacheCreationInputTokens: 0, costUSD: 0.01 },
        },
      };
    })();
  const s = new ClaudeSession(db, "s1", "/tmp", query as any);
  const ws = fakeWs();
  s.attach(ws);
  s.start();
  s.pushUser("hi");
  await waitFor(() => ws.frames.some((f: any) => f.t === "result"));
  const rows = db.prepare("SELECT * FROM usage_events ORDER BY cost_usd DESC").all() as any[];
  assert.equal(rows.length, 2);
  assert.deepEqual(
    [rows[0].provider, rows[0].model, rows[0].project_id, rows[0].input_tokens, rows[0].cache_read, rows[0].cache_write],
    ["anthropic", "claude-opus-4-8", "p1", 12, 5000, 200],
  );
  s.stop();
});

test("native turns record provider, uncached input and cache reads", async () => {
  const db = openDb(":memory:");
  seed(db);
  const stream = () => ({
    fullStream: (async function* () {
      yield { type: "text-delta", text: "ok" };
      yield { type: "finish", totalUsage: { inputTokens: 1000, outputTokens: 10, inputTokenDetails: { cacheReadTokens: 800 } } };
    })(),
    response: Promise.resolve({ messages: [] }),
  });
  const s = new NativeSession(db, "s2", "/tmp", "openai:gpt-4o", stream as any);
  const ws = fakeWs();
  s.attach(ws);
  s.pushUser("hi");
  await waitFor(() => ws.frames.some((f: any) => f.t === "result"));
  const row = db.prepare("SELECT * FROM usage_events").get() as any;
  assert.deepEqual(
    [row.provider, row.model, row.project_id, row.input_tokens, row.cache_read, row.output_tokens],
    ["openai", "openai:gpt-4o", "p2", 200, 800, 10],
  );
  assert.ok(row.cost_usd > 0);
});

test("GET /spend?group=project reports each project's CLAUDE.md size", async () => {
  const { db, app, auth } = await setup();
  const dir = mkdtempSync(join(tmpdir(), "spend-md-"));
  writeFileSync(join(dir, "CLAUDE.md"), "x".repeat(1234));
  db.prepare("UPDATE projects SET path = ? WHERE id = 'p1'").run(dir);
  recordUsage(db, { sessionId: "s1", provider: "anthropic", model: "m", input: 1, output: 1, cost: 0.01 });
  recordUsage(db, { sessionId: "s2", provider: "anthropic", model: "m", input: 1, output: 1, cost: 0.001 });
  const r = (await app.inject({ method: "GET", url: "/spend?group=project", headers: auth })).json();
  assert.deepEqual(r.rows.map((x: any) => [x.key, x.claudeMdBytes]), [["p1", 1234], ["p2", null]]);
  rmSync(dir, { recursive: true });
});

test("GET /spend/session/:id → that session's totals, per model; 401 without a token", async () => {
  const { db, app, auth } = await setup();
  recordUsage(db, { sessionId: "s1", provider: "anthropic", model: "opus", input: 100, output: 50, cacheRead: 900, cost: 0.2 });
  recordUsage(db, { sessionId: "s1", provider: "anthropic", model: "haiku", input: 10, output: 5, cost: 0.01 });
  recordUsage(db, { sessionId: "s2", provider: "anthropic", model: "opus", input: 7, output: 7, cost: 5 });
  const r = (await app.inject({ method: "GET", url: "/spend/session/s1", headers: auth })).json();
  assert.equal(r.totals.turns, 2);
  assert.equal(r.totals.cacheRead, 900);
  assert.deepEqual(r.rows.map((x: any) => x.key), ["opus", "haiku"]);
  const none = (await app.inject({ method: "GET", url: "/spend/session/nope", headers: auth })).json();
  assert.equal(none.totals.turns, 0);
  assert.deepEqual(none.rows, []);
  assert.equal((await app.inject({ method: "GET", url: "/spend/session/s1" })).statusCode, 401);
});

// ---- cumulative → delta (SDK modelUsage is a running total, even across resume) ------------

const cum = (o: number, c: number) => ({ sessionId: "s1", provider: "anthropic", model: "m", input: 0, output: o, cost: c });
const sumOut = (db: DB) => (db.prepare("SELECT COALESCE(SUM(output_tokens),0) t, COUNT(*) n FROM usage_events").get() as { t: number; n: number });

test("counterDelta never goes negative", () => {
  const z = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0 };
  assert.deepEqual(counterDelta({ ...z, output: 10 }, { ...z, output: 4 }), z);
  assert.equal(counterDelta({ ...z, output: 10 }, { ...z, output: 25 }).output, 15);
});

test("recordCumulative records only the increase per turn; unchanged turn records nothing", () => {
  const db = openDb(":memory:");
  recordCumulative(db, cum(35, 0.09));
  recordCumulative(db, cum(71, 0.10));
  recordCumulative(db, cum(71, 0.10));
  assert.deepEqual(sumOut(db), { t: 71, n: 2 });
  assert.ok(Math.abs((db.prepare("SELECT SUM(cost_usd) c FROM usage_events").get() as { c: number }).c - 0.10) < 1e-9);
});

test("a reading below the baseline records nothing and re-baselines", () => {
  const db = openDb(":memory:");
  recordCumulative(db, cum(100, 1));
  recordCumulative(db, cum(5, 0.1)); // reset blip
  recordCumulative(db, cum(8, 0.15));
  assert.equal(sumOut(db).t, 103);
});

test("cumulativeCostDelta tracks the session total", () => {
  const db = openDb(":memory:");
  assert.equal(cumulativeCostDelta(db, "s1", 0.05), 0.05);
  assert.ok(Math.abs(cumulativeCostDelta(db, "s1", 0.12) - 0.07) < 1e-9);
  assert.equal(cumulativeCostDelta(db, "s1", 0.12), 0);
});

test("migrateLedgerToDeltas rewrites cumulative rows once, keeps a backup, leaves native rows alone", () => {
  const db = openDb(":memory:");
  db.exec("DROP TABLE IF EXISTS usage_events_cumulative_backup");
  seed(db);
  const ins = db.prepare("INSERT INTO usage_events (id, session_id, project_id, provider, model, input_tokens, output_tokens, cache_read, cache_write, cost_usd, ts) VALUES (?,?,?,?,?,?,?,?,?,?,?)");
  ins.run("a", "s1", null, "anthropic", "m", 0, 10, 0, 0, 1, 1);
  ins.run("b", "s1", null, "anthropic", "m", 0, 25, 0, 0, 2.5, 2);
  ins.run("c", "s1", null, "anthropic", "m", 0, 25, 0, 0, 2.5, 3);
  ins.run("n", "s1", null, "openai", "gpt", 0, 7, 0, 0, 0.1, 2);
  const r = migrateLedgerToDeltas(db);
  assert.deepEqual(r, { rewritten: 3 });
  const out = (id: string) => (db.prepare("SELECT output_tokens o FROM usage_events WHERE id = ?").get(id) as { o: number }).o;
  assert.deepEqual([out("a"), out("b"), out("c"), out("n")], [10, 15, 0, 7]);
  assert.equal(migrateLedgerToDeltas(db), null); // idempotent
  assert.equal((db.prepare("SELECT COUNT(*) n FROM usage_events_cumulative_backup").get() as { n: number }).n, 4);
  // baseline seeded → next live turn only adds the increase
  recordCumulative(db, { sessionId: "s1", provider: "anthropic", model: "m", input: 0, output: 30, cost: 3 });
  assert.equal(out("n"), 7);
  assert.equal((db.prepare("SELECT SUM(output_tokens) t FROM usage_events WHERE provider='anthropic'").get() as { t: number }).t, 30);
});
