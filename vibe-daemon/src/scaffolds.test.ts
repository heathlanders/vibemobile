// Scaffold library CRUD verification (proposal 17). Drives the app via inject()
// against an in-memory DB. Covers the first-run seed, the CRUD lifecycle, and the
// path-containment guard that keeps a malicious scaffold from escaping on write.

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
  return { db, app, auth: { authorization: `Bearer ${token}` } };
}

test("the foundations scaffold is seeded once on first run", async () => {
  const { app, auth } = await setup();
  const seed = await app.inject({ method: "GET", url: "/scaffolds/seed-foundations", headers: auth });
  assert.equal(seed.statusCode, 200);
  assert.match(seed.json().name, /Foundations/);
  const files = JSON.parse(seed.json().files_json);
  assert.ok(files.some((f: any) => f.path === "CLAUDE.md"), "ships a CLAUDE.md");
  assert.ok(files.some((f: any) => f.path === "docs/README.md"), "ships the docs skeleton");

  const all = (await app.inject({ method: "GET", url: "/scaffolds", headers: auth })).json();
  assert.equal(all.filter((s: any) => s.id === "seed-foundations").length, 1);
});

test("create → get → update → delete lifecycle", async () => {
  const { app, auth } = await setup();
  const created = await app.inject({
    method: "POST",
    url: "/scaffolds",
    headers: auth,
    payload: { name: "Node lib", files: [{ path: "README.md", body: "# {{project_name}}" }] },
  });
  assert.equal(created.statusCode, 201);
  const id = created.json().id;

  const updated = await app.inject({ method: "PUT", url: `/scaffolds/${id}`, headers: auth, payload: { name: "Node lib v2" } });
  assert.equal(updated.statusCode, 200);
  assert.equal(updated.json().name, "Node lib v2");
  assert.equal(JSON.parse(updated.json().files_json)[0].path, "README.md", "untouched files preserved");

  assert.equal((await app.inject({ method: "DELETE", url: `/scaffolds/${id}`, headers: auth })).statusCode, 204);
  assert.equal((await app.inject({ method: "GET", url: `/scaffolds/${id}`, headers: auth })).statusCode, 404);
});

test("POST requires name and a files array", async () => {
  const { app, auth } = await setup();
  assert.equal((await app.inject({ method: "POST", url: "/scaffolds", headers: auth, payload: { name: "x" } })).statusCode, 400);
});

test("POST rejects a path that escapes the project dir", async () => {
  const { app, auth } = await setup();
  for (const path of ["../escape.txt", "/etc/passwd", "a/../../b"]) {
    const res = await app.inject({ method: "POST", url: "/scaffolds", headers: auth, payload: { name: "bad", files: [{ path, body: "x" }] } });
    assert.equal(res.statusCode, 400, `rejected ${path}`);
  }
});

test("scaffold routes reject unauthenticated", async () => {
  const { app } = await setup();
  assert.equal((await app.inject({ method: "GET", url: "/scaffolds" })).statusCode, 401);
});

// ---- work standard (ADR 0028) --------------------------------------------------------------

test("Foundations ships the work standard, in sync with docs/WORKFLOW.md", async () => {
  const { readFileSync } = await import("node:fs");
  const { FOUNDATIONS_FILES } = await import("./scaffold-seed.js");
  const paths = FOUNDATIONS_FILES.map((f) => f.path);
  assert.ok(paths.includes("docs/WORKFLOW.md") && paths.includes("docs/handoffs/.gitkeep"));
  const seeded = FOUNDATIONS_FILES.find((f) => f.path === "docs/WORKFLOW.md")!.body;
  const doc = readFileSync(new URL("../../docs/WORKFLOW.md", import.meta.url), "utf8").replace(" (ADR 0028)", "");
  assert.equal(seeded, doc);
  assert.match(FOUNDATIONS_FILES.find((f) => f.path === "CLAUDE.md")!.body, /Work standard/);
});

test("an unedited seed row is refreshed to the shipped content; an edited one is left alone", async () => {
  const { openDb } = await import("./db.js");
  const { FOUNDATIONS_FILES } = await import("./scaffold-seed.js");
  const { mkdtempSync, rmSync } = await import("node:fs");
  const { tmpdir } = await import("node:os");
  const { join } = await import("node:path");
  const dir = mkdtempSync(join(tmpdir(), "seedrow-"));
  const file = join(dir, "v.db");
  try {
    let db = openDb(file);
    db.prepare("UPDATE scaffolds SET files_json = '[]' WHERE id = 'seed-foundations'").run(); // stale, same timestamps
    db.close();
    db = openDb(file);
    const get = () => (db.prepare("SELECT files_json FROM scaffolds WHERE id = 'seed-foundations'").get() as { files_json: string }).files_json;
    assert.equal(get(), JSON.stringify(FOUNDATIONS_FILES));
    db.prepare("UPDATE scaffolds SET files_json = '[]', updated_at = '2999-01-01' WHERE id = 'seed-foundations'").run(); // user-edited
    db.close();
    db = openDb(file);
    assert.equal(get(), "[]");
    db.close();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("the work-standard prompts are seeded once", async () => {
  const { openDb } = await import("./db.js");
  const db = openDb(":memory:");
  const ids = (db.prepare("SELECT id FROM prompts WHERE id LIKE 'seed-work-%'").all() as { id: string }[]).map((r) => r.id).sort();
  assert.deepEqual(ids, ["seed-work-close-milestone", "seed-work-handoff", "seed-work-proposal", "seed-work-resume"]);
});
