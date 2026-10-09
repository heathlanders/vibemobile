// @file autocomplete read surface (ADR 0010, security.md #13). The focus is
// containment: session scope, root scope, no symlink follow, excluded dirs,
// capped results with a visible truncated flag, and an audit row.

import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { openDb } from "./db.js";
import { buildApp } from "./app.js";
import { createPairingCode } from "./auth.js";
import { walkFiles } from "./project-tree.js";

const ROOT = mkdtempSync(join(tmpdir(), "vibe-tree-"));
const OUTSIDE = mkdtempSync(join(tmpdir(), "vibe-outside-"));
process.env.VIBE_PROJECT_ROOTS = ROOT;

// project layout: a.dart, lib/theme.dart, .git/config, node_modules/dep.js,
// plus a symlink pointing outside the root.
mkdirSync(join(ROOT, "lib"), { recursive: true });
mkdirSync(join(ROOT, ".git"), { recursive: true });
mkdirSync(join(ROOT, "node_modules"), { recursive: true });
writeFileSync(join(ROOT, "a.dart"), "x");
writeFileSync(join(ROOT, "lib", "theme.dart"), "x");
writeFileSync(join(ROOT, ".git", "config"), "secret");
writeFileSync(join(ROOT, "node_modules", "dep.js"), "x");
writeFileSync(join(OUTSIDE, "private.txt"), "secret");
symlinkSync(OUTSIDE, join(ROOT, "escape"));

async function setup() {
  const db = openDb(":memory:");
  const app = await buildApp(db);
  const { token } = (
    await app.inject({ method: "POST", url: "/pair", payload: { code: createPairingCode(db), device_name: "t" } })
  ).json();
  const auth = { authorization: `Bearer ${token}` };
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES (?,?,?,?)").run("p", ROOT, "t", "unknown");
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES (?,?,?,?)").run("pout", OUTSIDE, "o", "unknown");
  db.prepare("INSERT INTO sessions (id, project_id, kind, created_at) VALUES (?,?,?,?)").run(
    "s1",
    "p",
    "claude",
    new Date().toISOString(),
  );
  db.prepare("INSERT INTO sessions (id, project_id, kind, created_at) VALUES (?,?,?,?)").run(
    "sout",
    "pout",
    "claude",
    new Date().toISOString(),
  );
  return { db, app, auth };
}

const get = (app: any, auth: any, url: string) => app.inject({ method: "GET", url, headers: auth });

// ---- walk ----------------------------------------------------------------

test("walk lists project files and filters case-insensitively", async () => {
  const all = walkFiles(ROOT, "", 50).files.map((f) => f.relPath).sort();
  assert.deepEqual(all, ["a.dart", join("lib", "theme.dart")].sort());

  const hit = walkFiles(ROOT, "THEME", 50).files.map((f) => f.relPath);
  assert.deepEqual(hit, [join("lib", "theme.dart")]);
});

test("walk excludes dotdirs, dependency dirs and symlinks", async () => {
  const rels = walkFiles(ROOT, "", 50).files.map((f) => f.relPath);
  assert.ok(!rels.some((r) => r.includes(".git")), ".git must never be listed");
  assert.ok(!rels.some((r) => r.includes("node_modules")), "node_modules must never be listed");
  assert.ok(!rels.some((r) => r.includes("private.txt")), "a symlink must not escape the root");
  assert.ok(!rels.some((r) => r.includes("escape")), "symlinks are skipped entirely");
});

test("walk caps results and flags the cut instead of truncating silently", async () => {
  const res = walkFiles(ROOT, "", 1);
  assert.equal(res.files.length, 1);
  assert.equal(res.truncated, true);
});

// ---- route ---------------------------------------------------------------

test("route returns the session's project files and audits the read", async () => {
  const { db, app, auth } = await setup();
  const res = await get(app, auth, "/sessions/s1/tree?q=dart");
  assert.equal(res.statusCode, 200);
  const body = res.json();
  assert.equal(body.root, ROOT);
  assert.equal(body.truncated, false);
  assert.deepEqual(
    body.files.map((f: any) => f.relPath).sort(),
    ["a.dart", join("lib", "theme.dart")].sort(),
  );

  const evt = db.prepare("SELECT kind, detail FROM events WHERE kind = 'session.tree'").get() as any;
  assert.equal(evt.kind, "session.tree");
  assert.ok(evt.detail.startsWith("s1:"));
});

test("route caps limit at the server maximum", async () => {
  const { app, auth } = await setup();
  const res = await get(app, auth, "/sessions/s1/tree?limit=9999");
  assert.equal(res.statusCode, 200);
  assert.ok(res.json().files.length <= 50);
});

test("route refuses a project outside VIBE_PROJECT_ROOTS", async () => {
  const { app, auth } = await setup();
  const res = await get(app, auth, "/sessions/sout/tree");
  assert.equal(res.statusCode, 403);
});

test("route 404s an unknown session", async () => {
  const { app, auth } = await setup();
  assert.equal((await get(app, auth, "/sessions/nope/tree")).statusCode, 404);
});

test("route requires a bearer token", async () => {
  const { app } = await setup();
  const res = await app.inject({ method: "GET", url: "/sessions/s1/tree" });
  assert.equal(res.statusCode, 401);
});
