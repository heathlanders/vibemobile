// Session image read surface (proposal 33, ADR 0021, security.md #23). Focus is
// containment: session project scope (not just any root), symlink escape, image
// bytes only (magic sniff, not the extension), size cap, and an audit row.

import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { openDb } from "./db.js";
import { buildApp } from "./app.js";
import { createPairingCode } from "./auth.js";

const ROOTS = mkdtempSync(join(tmpdir(), "vibe-img-"));
const PROJ = join(ROOTS, "proj");
const SIBLING = join(ROOTS, "sibling");
const OUTSIDE = mkdtempSync(join(tmpdir(), "vibe-img-out-"));
process.env.VIBE_PROJECT_ROOTS = ROOTS;
process.env.VIBE_MAX_ATTACH_BYTES = String(5 * 1024 * 1024);

const PNG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0]);
mkdirSync(join(PROJ, "out"), { recursive: true });
mkdirSync(SIBLING, { recursive: true });
writeFileSync(join(PROJ, "out", "chart.png"), PNG);
writeFileSync(join(PROJ, "secret.png"), "API_KEY=hunter2"); // lies about being an image
writeFileSync(join(PROJ, "big.png"), Buffer.concat([PNG, Buffer.alloc(6 * 1024 * 1024)]));
writeFileSync(join(SIBLING, "other.png"), PNG);
writeFileSync(join(OUTSIDE, "x.png"), PNG);
symlinkSync(join(OUTSIDE, "x.png"), join(PROJ, "escape.png"));

async function setup() {
  const db = openDb(":memory:");
  const app = await buildApp(db);
  const { token } = (
    await app.inject({ method: "POST", url: "/pair", payload: { code: createPairingCode(db), device_name: "t" } })
  ).json();
  const auth = { authorization: `Bearer ${token}` };
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES (?,?,?,?)").run("p", PROJ, "t", "unknown");
  db.prepare("INSERT INTO sessions (id, project_id, kind, created_at) VALUES (?,?,?,?)").run(
    "s",
    "p",
    "claude",
    new Date().toISOString(),
  );
  const get = (path: string, id = "s") =>
    app.inject({ method: "GET", url: `/sessions/${id}/image?path=${encodeURIComponent(path)}`, headers: auth });
  return { db, app, get };
}

test("requires auth", async () => {
  const { app } = await setup();
  assert.equal((await app.inject({ method: "GET", url: "/sessions/s/image?path=out/chart.png" })).statusCode, 401);
});

test("serves an image in the project (relative and absolute), audited", async () => {
  const { db, get } = await setup();
  for (const p of ["out/chart.png", "./out/chart.png", join(PROJ, "out", "chart.png")]) {
    const res = await get(p);
    assert.equal(res.statusCode, 200, p);
    assert.equal(res.headers["content-type"], "image/png");
    assert.deepEqual(res.rawPayload, PNG);
  }
  const ev = db.prepare("SELECT detail FROM events WHERE kind = 'file.image'").all() as any[];
  assert.equal(ev.length, 3);
  assert.equal(ev[0].detail, `s:${join("out", "chart.png")}:${PNG.length}`);
});

test("refuses paths outside the session's project", async () => {
  const { get } = await setup();
  assert.equal((await get("../sibling/other.png")).statusCode, 403, "sibling project in roots");
  assert.equal((await get(join(OUTSIDE, "x.png"))).statusCode, 403, "absolute outside");
  assert.equal((await get("escape.png")).statusCode, 403, "symlink out of root");
  assert.equal((await get("../../../../etc/passwd")).statusCode, 403);
});

test("serves image bytes only — sniff, not extension", async () => {
  const { get } = await setup();
  assert.equal((await get("secret.png")).statusCode, 415);
});

test("size cap, missing file, directory, unknown session", async () => {
  const { get } = await setup();
  assert.equal((await get("big.png")).statusCode, 413);
  assert.equal((await get("nope.png")).statusCode, 404);
  assert.equal((await get("out")).statusCode, 404);
  assert.equal((await get("out/chart.png", "nope")).statusCode, 404);
  assert.equal((await get("")).statusCode, 400);
});
