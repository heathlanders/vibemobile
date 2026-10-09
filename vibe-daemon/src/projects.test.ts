// Project creation verification (proposal 17). Uses a real temp dir as the
// project root (VIBE_PROJECT_ROOTS) so the filesystem write + git shell-out run
// for real. Covers the happy path (dir + substituted files + git author), name
// validation, no-overwrite, and the write-time containment guard against a
// malicious stored scaffold.

import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { openDb } from "./db.js";
import { buildApp } from "./app.js";
import { createPairingCode } from "./auth.js";

// One temp root for the whole file; project names are unique per test.
const ROOT = mkdtempSync(join(tmpdir(), "vibe-proj-"));
process.env.VIBE_PROJECT_ROOTS = ROOT;

async function setup() {
  const db = openDb(":memory:");
  const app = await buildApp(db);
  const { token } = (
    await app.inject({ method: "POST", url: "/pair", payload: { code: createPairingCode(db), device_name: "phone" } })
  ).json();
  return { db, app, auth: { authorization: `Bearer ${token}` } };
}

test("create with the foundations scaffold writes substituted files + a git commit", async () => {
  const { app, auth } = await setup();
  const res = await app.inject({
    method: "POST",
    url: "/projects",
    headers: auth,
    payload: { name: "railroad-saas", scaffold_id: "seed-foundations", git: true },
  });
  assert.equal(res.statusCode, 201);
  assert.equal(res.json().name, "railroad-saas");

  const dir = join(ROOT, "railroad-saas");
  assert.ok(existsSync(join(dir, "CLAUDE.md")), "CLAUDE.md written");
  assert.ok(existsSync(join(dir, "docs", "README.md")), "docs skeleton written");
  assert.ok(existsSync(join(dir, "docs", "protocols", ".gitkeep")), "empty dirs kept");

  const claude = readFileSync(join(dir, "CLAUDE.md"), "utf8");
  assert.match(claude, /railroad-saas/, "{{project_name}} substituted");
  assert.ok(!claude.includes("{{project_name}}"), "no leftover token");

  assert.ok(existsSync(join(dir, ".git")), "git repo initialised");
  const author = execFileSync("git", ["log", "-1", "--format=%an"], { cwd: dir, encoding: "utf8" }).trim();
  assert.equal(author, "phone", "commit attributed to the paired device");
});

test("bare create (no scaffold) makes the dir + an init-only repo", async () => {
  const { app, auth } = await setup();
  const res = await app.inject({ method: "POST", url: "/projects", headers: auth, payload: { name: "bare-proj", git: true } });
  assert.equal(res.statusCode, 201);
  const dir = join(ROOT, "bare-proj");
  assert.ok(existsSync(join(dir, ".git")), "repo exists");
  // No files → no commit; HEAD has no commits yet.
  assert.throws(() => execFileSync("git", ["rev-parse", "HEAD"], { cwd: dir, stdio: "pipe" }), "no commit on empty repo");
});

test("invalid names are rejected", async () => {
  const { app, auth } = await setup();
  for (const name of ["../evil", "foo/bar", ".hidden", "", "has space"]) {
    const res = await app.inject({ method: "POST", url: "/projects", headers: auth, payload: { name } });
    assert.equal(res.statusCode, 400, `rejected ${JSON.stringify(name)}`);
  }
});

test("creating an existing project name is refused", async () => {
  const { app, auth } = await setup();
  const first = await app.inject({ method: "POST", url: "/projects", headers: auth, payload: { name: "dup", git: false } });
  assert.equal(first.json().name, "dup", "a bare git-less create is still returned (and listed)");
  const again = await app.inject({ method: "POST", url: "/projects", headers: auth, payload: { name: "dup", git: false } });
  assert.equal(again.statusCode, 409);
});

test("unknown scaffold_id is a 404", async () => {
  const { app, auth } = await setup();
  const res = await app.inject({ method: "POST", url: "/projects", headers: auth, payload: { name: "p", scaffold_id: "nope" } });
  assert.equal(res.statusCode, 404);
});

test("a stored scaffold with an escaping path can't write outside the target", async () => {
  const { db, app, auth } = await setup();
  // Bypass CRUD validation to plant a malicious row, then prove create re-checks.
  const now = new Date().toISOString();
  db.prepare("INSERT INTO scaffolds (id, name, description, files_json, created_at, updated_at) VALUES (?,?,?,?,?,?)").run(
    "evil",
    "evil",
    null,
    JSON.stringify([{ path: "../../escaped.txt", body: "pwned" }]),
    now,
    now,
  );
  const res = await app.inject({ method: "POST", url: "/projects", headers: auth, payload: { name: "victim", scaffold_id: "evil", git: false } });
  assert.equal(res.statusCode, 400, "create re-validates and refuses");
  assert.ok(!existsSync(join(ROOT, "victim")), "no dir left behind");
  assert.ok(!existsSync(join(ROOT, "..", "escaped.txt")), "nothing written outside root");
});

test("project create rejects unauthenticated", async () => {
  const { app } = await setup();
  assert.equal((await app.inject({ method: "POST", url: "/projects", payload: { name: "x" } })).statusCode, 401);
});
