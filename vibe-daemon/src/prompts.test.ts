// Prompt library CRUD verification. Drives the app via inject() + auth against an
// in-memory DB. Covers the first-run seed, the CRUD lifecycle, and the
// global+project filter.

import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import Database from "better-sqlite3";
import { openDb } from "./db.js";
import { buildApp } from "./app.js";
import { createPairingCode } from "./auth.js";

async function setup() {
  const db = openDb(":memory:");
  const app = await buildApp(db);
  const { token } = (
    await app.inject({ method: "POST", url: "/pair", payload: { code: createPairingCode(db), device_name: "t" } })
  ).json();
  const auth = { authorization: `Bearer ${token}` };
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES (?,?,?,?)").run("p1", "/home/user/vibemobile", "vm", "unknown");
  return { db, app, auth };
}

test("the Karpathy guidelines prompt is seeded on first run", async () => {
  const { app, auth } = await setup();
  const seed = await app.inject({ method: "GET", url: "/prompts/seed-karpathy", headers: auth });
  assert.equal(seed.statusCode, 200);
  assert.match(seed.json().title, /Karpathy/);
  assert.equal(seed.json().project_id, null); // global
});

test("seed is inserted once (idempotent across openDb)", async () => {
  const { app, auth } = await setup();
  const all = await app.inject({ method: "GET", url: "/prompts", headers: auth });
  assert.equal(all.json().filter((p: any) => p.id === "seed-karpathy").length, 1);
});

test("create → get → update → delete lifecycle", async () => {
  const { app, auth } = await setup();
  const created = await app.inject({
    method: "POST",
    url: "/prompts",
    headers: auth,
    payload: { title: "Refactor", body: "Refactor {{file}} for {{goal}}", tags: "refactor" },
  });
  assert.equal(created.statusCode, 201);
  const id = created.json().id;
  assert.equal(created.json().body, "Refactor {{file}} for {{goal}}");

  const updated = await app.inject({ method: "PUT", url: `/prompts/${id}`, headers: auth, payload: { title: "Refactor v2" } });
  assert.equal(updated.statusCode, 200);
  assert.equal(updated.json().title, "Refactor v2");
  assert.equal(updated.json().body, "Refactor {{file}} for {{goal}}", "untouched fields preserved");

  assert.equal((await app.inject({ method: "DELETE", url: `/prompts/${id}`, headers: auth })).statusCode, 204);
  assert.equal((await app.inject({ method: "GET", url: `/prompts/${id}`, headers: auth })).statusCode, 404);
});

test("POST requires title and body", async () => {
  const { app, auth } = await setup();
  assert.equal((await app.inject({ method: "POST", url: "/prompts", headers: auth, payload: { title: "x" } })).statusCode, 400);
});

test("POST with an unknown project_id is rejected", async () => {
  const { app, auth } = await setup();
  const res = await app.inject({ method: "POST", url: "/prompts", headers: auth, payload: { title: "t", body: "b", project_id: "nope" } });
  assert.equal(res.statusCode, 404);
});

test("?project_id filter returns globals + that project's prompts only", async () => {
  const { db, app, auth } = await setup();
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES (?,?,?,?)").run("p2", "/home/user/other", "other", "unknown");
  const mk = (title: string, project_id: string | null) =>
    app.inject({ method: "POST", url: "/prompts", headers: auth, payload: { title, body: "b", project_id } });
  await mk("p1-only", "p1");
  await mk("p2-only", "p2");

  const list = (await app.inject({ method: "GET", url: "/prompts?project_id=p1", headers: auth })).json();
  const titles = list.map((p: any) => p.title);
  assert.ok(titles.includes("p1-only"));
  assert.ok(titles.includes("Karpathy guidelines"), "globals included");
  assert.ok(!titles.includes("p2-only"), "other project's prompt excluded");
});

test("prompts routes reject unauthenticated", async () => {
  const { app } = await setup();
  assert.equal((await app.inject({ method: "GET", url: "/prompts" })).statusCode, 401);
});

test("always_apply: both packs seeded on; flag round-trips as a boolean", async () => {
  const { app, auth } = await setup();
  const get = async (id: string) => (await app.inject({ method: "GET", url: `/prompts/${id}`, headers: auth })).json();
  assert.equal((await get("seed-karpathy")).always_apply, true);
  assert.equal((await get("seed-ambition")).always_apply, true);
  assert.ok((await get("seed-ambition")).body.length <= 1500);
  assert.equal((await get("seed-work-handoff")).always_apply, false);
});

test("always_apply: {{vars}} rejected on create, update, and body-only edits of a flagged prompt", async () => {
  const { app, auth } = await setup();
  const send = (method: "POST" | "PUT", url: string, payload: object) => app.inject({ method, url, headers: auth, payload });
  assert.equal((await send("POST", "/prompts", { title: "t", body: "fix {{file}}", always_apply: true })).statusCode, 400);
  assert.equal((await send("POST", "/prompts", { title: "t", body: "ok", always_apply: "yes" })).statusCode, 400);
  const tpl = (await send("POST", "/prompts", { title: "t", body: "fix {{file}}" })).json();
  assert.equal(tpl.always_apply, false);
  assert.equal((await send("PUT", `/prompts/${tpl.id}`, { always_apply: true })).statusCode, 400);
  const rule = (await send("POST", "/prompts", { title: "r", body: "be careful", always_apply: true })).json();
  assert.equal(rule.always_apply, true);
  assert.equal((await send("PUT", `/prompts/${rule.id}`, { body: "be {{how}}" })).statusCode, 400);
  assert.equal((await send("PUT", `/prompts/${rule.id}`, { body: "be very careful" })).json().always_apply, true);
});

test("always_apply: toggles and create/delete are audited by id, never the body", async () => {
  const { db, app, auth } = await setup();
  const send = (method: "POST" | "PUT" | "DELETE", url: string, payload?: object) => app.inject({ method, url, headers: auth, payload });
  const id = (await send("POST", "/prompts", { title: "r", body: "SECRET-BODY", always_apply: true })).json().id;
  await send("PUT", `/prompts/${id}`, { title: "renamed" }); // no change → no entry
  await send("PUT", `/prompts/${id}`, { always_apply: false });
  await send("PUT", `/prompts/${id}`, { always_apply: true });
  await send("DELETE", `/prompts/${id}`);
  const rows = db.prepare("SELECT detail FROM events WHERE kind = 'prompt.always_apply' ORDER BY rowid").all() as { detail: string }[];
  assert.deepEqual(rows.map((r) => r.detail), [`${id}=on`, `${id}=off`, `${id}=on`, `${id}=off`]);
  assert.ok(!JSON.stringify(db.prepare("SELECT * FROM events").all()).includes("SECRET-BODY"));
});

test("always_apply migration: switches Karpathy on exactly once", () => {
  const file = join(mkdtempSync(join(tmpdir(), "vibe-aa-")), "old.db");
  const old = new Database(file);
  old.exec(`CREATE TABLE prompts (id TEXT PRIMARY KEY, title TEXT NOT NULL, body TEXT NOT NULL, tags TEXT, project_id TEXT,
    vars_json TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, use_count INTEGER NOT NULL DEFAULT 0, last_used_at TEXT);
    INSERT INTO prompts (id, title, body, created_at, updated_at) VALUES ('seed-karpathy','K','b','x','x'), ('other','O','b','x','x');`);
  old.close();
  const flags = (db: ReturnType<typeof openDb>) =>
    Object.fromEntries((db.prepare("SELECT id, always_apply a FROM prompts").all() as any[]).map((r) => [r.id, r.a]));
  const db1 = openDb(file);
  assert.deepEqual(flags(db1), { "seed-karpathy": 1, other: 0, "seed-ambition": 1, ...Object.fromEntries(["handoff", "resume", "proposal", "close-milestone"].map((n) => [`seed-work-${n}`, 0])) });
  db1.prepare("UPDATE prompts SET always_apply = 0 WHERE id = 'seed-karpathy'").run(); // user turns it off
  db1.close();
  assert.equal(flags(openDb(file))["seed-karpathy"], 0, "re-open must not re-enable it");
});
