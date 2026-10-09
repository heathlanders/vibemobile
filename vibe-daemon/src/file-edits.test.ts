// Session file viewer verification (proposal 20). Drives the real app via
// inject() against an in-memory DB with hand-seeded tool rows — the same shape
// claude.ts persists. Security gate is the focus for /sessions/:id/file:
// edit-set capability, root scope, binary sniff, size cap, audit.

import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { openDb } from "./db.js";
import { buildApp } from "./app.js";
import { createPairingCode } from "./auth.js";
import { collectFileEdits, buildEditDiff } from "./file-edits.js";

// Project root inside a tmp dir so file reads hit real files scoped by
// VIBE_PROJECT_ROOTS (paths.ts reads it per-call).
const ROOT = mkdtempSync(join(tmpdir(), "vibe-fileedits-"));
process.env.VIBE_PROJECT_ROOTS = ROOT;

let n = 0;
const seedTool = (db: any, sessionId: string, json: unknown) =>
  db.prepare("INSERT INTO messages (id, session_id, role, content, tool_json, ts) VALUES (?,?,?,?,?,?)").run(
    `m${n}`,
    sessionId,
    "tool",
    null,
    JSON.stringify(json),
    new Date(2026, 0, 1, 0, 0, n++).toISOString(),
  );

async function setup() {
  const db = openDb(":memory:");
  const app = await buildApp(db);
  const { token } = (
    await app.inject({ method: "POST", url: "/pair", payload: { code: createPairingCode(db), device_name: "t" } })
  ).json();
  const auth = { authorization: `Bearer ${token}` };
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES (?,?,?,?)").run("p", ROOT, "t", "unknown");
  db.prepare("INSERT INTO sessions (id, project_id, kind, created_at) VALUES (?,?,?,?)").run(
    "s1",
    "p",
    "claude",
    new Date().toISOString(),
  );
  return { db, app, auth };
}

const get = (app: any, auth: any, url: string) => app.inject({ method: "GET", url, headers: auth });

// ---- aggregation ----------------------------------------------------------

test("list aggregates edits per file with counts; written flag on Write", async () => {
  const { db, app, auth } = await setup();
  const f = join(ROOT, "a.txt");
  seedTool(db, "s1", { id: "t1", name: "Edit", input: { file_path: f, old_string: "one", new_string: "two\nthree" }, result: "ok" });
  seedTool(db, "s1", { id: "t2", name: "Edit", input: { file_path: f, old_string: "x", new_string: "y" }, result: "ok" });
  seedTool(db, "s1", { id: "t3", name: "Write", input: { file_path: join(ROOT, "b.txt"), content: "l1\nl2" }, result: "ok" });
  const res = await get(app, auth, "/sessions/s1/file-edits");
  assert.equal(res.statusCode, 200);
  const rows = res.json();
  assert.equal(rows.length, 2);
  const a = rows.find((r: any) => r.relPath === "a.txt");
  assert.equal(a.edits, 2);
  assert.equal(a.adds, 3); // two\nthree (2) + y (1)
  assert.equal(a.dels, 2); // one (1) + x (1)
  assert.equal(a.written, false);
  const b = rows.find((r: any) => r.relPath === "b.txt");
  assert.equal(b.written, true);
  assert.equal(b.adds, 2);
  assert.equal(b.dels, 0);
});

test("isError ops and non-write tools are skipped; MultiEdit flattens", async () => {
  const { db } = await setup();
  const f = join(ROOT, "c.txt");
  seedTool(db, "s1", { id: "t1", name: "Edit", input: { file_path: f, old_string: "a", new_string: "b" }, isError: true });
  seedTool(db, "s1", { id: "t2", name: "Read", input: { file_path: f } });
  seedTool(db, "s1", {
    id: "t3",
    name: "MultiEdit",
    input: { file_path: f, edits: [{ old_string: "a", new_string: "b" }, { old_string: "c", new_string: "d", replace_all: true }] },
  });
  const byPath = collectFileEdits(db, "s1");
  assert.equal(byPath.size, 1);
  const ops = byPath.get(f)!;
  assert.equal(ops.length, 2); // isError Edit + Read dropped; MultiEdit → 2 ops
  assert.equal(ops[1].replaceAll, true);
});

test("diff endpoint returns per-edit sections in ts order", async () => {
  const { db, app, auth } = await setup();
  const f = join(ROOT, "d.txt");
  seedTool(db, "s1", { id: "t1", name: "Edit", input: { file_path: f, old_string: "old line", new_string: "new line" }, result: "ok" });
  seedTool(db, "s1", { id: "t2", name: "Write", input: { file_path: f, content: "full" }, result: "ok" });
  const res = await get(app, auth, `/sessions/s1/file-edits/diff?path=${encodeURIComponent(f)}`);
  assert.equal(res.statusCode, 200);
  const body = res.json();
  assert.equal(body.relPath, "d.txt");
  assert.equal(body.edits.length, 2);
  assert.equal(body.edits[0].tool, "Edit");
  assert.match(body.edits[0].diff, /^@@ /);
  assert.match(body.edits[0].diff, /-old line/);
  assert.match(body.edits[0].diff, /\+new line/);
  assert.equal(body.edits[1].tool, "Write");
  assert.equal(body.edits[1].diff, "+full");
});

test("diff truncation appends visible marker and sets flag", () => {
  const big = Array.from({ length: 600 }, (_, i) => `line ${i}`).join("\n");
  const d = buildEditDiff({ ts: "", tool: "Write", replaceAll: false, written: true, oldStr: "", newStr: big });
  assert.equal(d.truncated, true);
  assert.match(d.diff, /… \+\d+ lines truncated$/);
  assert.equal(d.adds, 600); // counts reflect the full edit, not the cut
});

test("diff 404s for unknown path and unknown session", async () => {
  const { app, auth } = await setup();
  assert.equal((await get(app, auth, "/sessions/s1/file-edits/diff?path=/nope")).statusCode, 404);
  assert.equal((await get(app, auth, "/sessions/nope/file-edits")).statusCode, 404);
  assert.equal((await get(app, auth, "/sessions/nope/file-edits/diff?path=/x")).statusCode, 404);
  assert.equal((await get(app, auth, "/sessions/nope/file")).statusCode, 404);
});

// ---- file content route (security gate) -----------------------------------

test("file route serves content only for paths in the edit set, and audits", async () => {
  const { db, app, auth } = await setup();
  const f = join(ROOT, "e.txt");
  writeFileSync(f, "hello\nworld\n");
  const other = join(ROOT, "not-edited.txt");
  writeFileSync(other, "secret");
  seedTool(db, "s1", { id: "t1", name: "Write", input: { file_path: f, content: "hello\nworld\n" }, result: "ok" });

  const ok = await get(app, auth, `/sessions/s1/file?path=${encodeURIComponent(f)}`);
  assert.equal(ok.statusCode, 200);
  assert.equal(ok.json().content, "hello\nworld\n");
  assert.equal(ok.json().truncated, false);

  // Edit-set capability: an in-root file the session never touched is 404.
  assert.equal((await get(app, auth, `/sessions/s1/file?path=${encodeURIComponent(other)}`)).statusCode, 404);

  const ev = db.prepare("SELECT * FROM events WHERE kind = 'file.read'").all();
  assert.equal(ev.length, 1);
});

test("file route refuses out-of-roots paths even when in the edit set", async () => {
  const { db, app, auth } = await setup();
  seedTool(db, "s1", { id: "t1", name: "Write", input: { file_path: "/etc/hostname", content: "x" }, result: "ok" });
  assert.equal((await get(app, auth, "/sessions/s1/file?path=/etc/hostname")).statusCode, 403);
});

test("file route resolves symlinks before the scope check", async () => {
  const { db, app, auth } = await setup();
  const link = join(ROOT, "sneaky");
  symlinkSync("/etc/hostname", link);
  seedTool(db, "s1", { id: "t1", name: "Write", input: { file_path: link, content: "x" }, result: "ok" });
  assert.equal((await get(app, auth, `/sessions/s1/file?path=${encodeURIComponent(link)}`)).statusCode, 403);
});

test("file route 404s a deleted file and 415s binary content", async () => {
  const { db, app, auth } = await setup();
  const gone = join(ROOT, "gone.txt");
  seedTool(db, "s1", { id: "t1", name: "Write", input: { file_path: gone, content: "x" }, result: "ok" });
  assert.equal((await get(app, auth, `/sessions/s1/file?path=${encodeURIComponent(gone)}`)).statusCode, 404);

  const bin = join(ROOT, "bin.dat");
  writeFileSync(bin, Buffer.from([0x68, 0x69, 0x00, 0x01]));
  seedTool(db, "s1", { id: "t2", name: "Write", input: { file_path: bin, content: "irrelevant" }, result: "ok" });
  assert.equal((await get(app, auth, `/sessions/s1/file?path=${encodeURIComponent(bin)}`)).statusCode, 415);
});

test("routes require auth", async () => {
  const { app } = await setup();
  assert.equal((await app.inject({ method: "GET", url: "/sessions/s1/file-edits" })).statusCode, 401);
  assert.equal((await app.inject({ method: "GET", url: "/sessions/s1/file?path=/x" })).statusCode, 401);
});
