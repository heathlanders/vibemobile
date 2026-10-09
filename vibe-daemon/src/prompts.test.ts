// Prompt library CRUD verification. Drives the app via inject() + auth against an
// in-memory DB. Covers the first-run seed, the CRUD lifecycle, and the
// global+project filter.

import test from "node:test";
import assert from "node:assert/strict";
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
