// Project notes CRUD (proposal 31). Drives the app via inject() + auth against an
// in-memory DB, same setup as prompts.test.ts.

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

test("create → list → update → delete lifecycle", async () => {
  const { app, auth } = await setup();
  const created = await app.inject({ method: "POST", url: "/projects/p1/notes", headers: auth, payload: { text: "  idea  " } });
  assert.equal(created.statusCode, 201);
  const note = created.json();
  assert.equal(note.text, "idea");
  assert.equal(note.done, false);
  assert.equal(note.project_id, "p1");

  const list = await app.inject({ method: "GET", url: "/projects/p1/notes", headers: auth });
  assert.deepEqual(list.json().map((n: any) => n.id), [note.id]);

  const upd = await app.inject({ method: "PUT", url: `/notes/${note.id}`, headers: auth, payload: { done: true } });
  assert.equal(upd.statusCode, 200);
  assert.equal(upd.json().done, true);
  assert.equal(upd.json().text, "idea"); // partial edit keeps text

  const upd2 = await app.inject({ method: "PUT", url: `/notes/${note.id}`, headers: auth, payload: { text: "better idea" } });
  assert.equal(upd2.json().text, "better idea");
  assert.equal(upd2.json().done, true);

  assert.equal((await app.inject({ method: "DELETE", url: `/notes/${note.id}`, headers: auth })).statusCode, 204);
  assert.equal((await app.inject({ method: "DELETE", url: `/notes/${note.id}`, headers: auth })).statusCode, 204);
  assert.deepEqual((await app.inject({ method: "GET", url: "/projects/p1/notes", headers: auth })).json(), []);
});

test("list puts open items first (oldest first), done items last", async () => {
  const { db, app, auth } = await setup();
  const ins = db.prepare("INSERT INTO notes (id, project_id, text, done, created_at, updated_at) VALUES (?,?,?,?,?,?)");
  ins.run("a", "p1", "a", 1, "2026-01-01", "2026-01-05");
  ins.run("b", "p1", "b", 0, "2026-01-03", "2026-01-03");
  ins.run("c", "p1", "c", 0, "2026-01-02", "2026-01-02");
  ins.run("d", "p1", "d", 1, "2026-01-01", "2026-01-09");
  const list = await app.inject({ method: "GET", url: "/projects/p1/notes", headers: auth });
  assert.deepEqual(list.json().map((n: any) => n.id), ["c", "b", "d", "a"]);
});

test("validation: empty / too long text, bad done, unknown project or note", async () => {
  const { app, auth } = await setup();
  const post = (url: string, payload: unknown) => app.inject({ method: "POST", url, headers: auth, payload: payload as any });
  assert.equal((await post("/projects/p1/notes", { text: "   " })).statusCode, 400);
  assert.equal((await post("/projects/p1/notes", { text: "x".repeat(4001) })).statusCode, 400);
  assert.equal((await post("/projects/nope/notes", { text: "hi" })).statusCode, 404);
  assert.equal((await app.inject({ method: "GET", url: "/projects/nope/notes", headers: auth })).statusCode, 404);
  assert.equal((await app.inject({ method: "PUT", url: "/notes/nope", headers: auth, payload: { done: true } })).statusCode, 404);
  const id = (await post("/projects/p1/notes", { text: "hi" })).json().id;
  assert.equal((await app.inject({ method: "PUT", url: `/notes/${id}`, headers: auth, payload: { done: "yes" } })).statusCode, 400);
  assert.equal((await app.inject({ method: "PUT", url: `/notes/${id}`, headers: auth, payload: { text: "" } })).statusCode, 400);
});

test("requires auth", async () => {
  const { app } = await setup();
  assert.equal((await app.inject({ method: "GET", url: "/projects/p1/notes" })).statusCode, 401);
  assert.equal((await app.inject({ method: "POST", url: "/projects/p1/notes", payload: { text: "x" } })).statusCode, 401);
});

test("notes cascade-delete with their project", async () => {
  const { db, app, auth } = await setup();
  await app.inject({ method: "POST", url: "/projects/p1/notes", headers: auth, payload: { text: "x" } });
  db.prepare("DELETE FROM projects WHERE id = 'p1'").run();
  assert.equal((db.prepare("SELECT COUNT(*) n FROM notes").get() as { n: number }).n, 0);
});
