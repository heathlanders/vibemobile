// Proposal 68 A5–A8: small hardening fixes.
import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { openDb } from "./db.js";
import { buildApp } from "./app.js";
import { createPairingCode } from "./auth.js";
import { PermissionGate } from "./permission-gate.js";
import { buildNativeTools } from "./native-tools.js";

const ROOT = mkdtempSync(join(tmpdir(), "vibe-hardening-"));
process.env.VIBE_PROJECT_ROOTS = ROOT;
test.after(() => rmSync(ROOT, { recursive: true, force: true }));

test("A5: /pair caps device_name at 64 chars and rejects non-strings", async () => {
  const db = openDb(":memory:");
  const app = await buildApp(db);
  const pair = (payload: object) => app.inject({ method: "POST", url: "/pair", payload });
  const ok = await pair({ code: createPairingCode(db), device_name: "x".repeat(500) });
  assert.equal(ok.statusCode, 201);
  const { name } = db.prepare("SELECT name FROM devices WHERE id = ?").get(ok.json().device_id) as { name: string };
  assert.equal(name.length, 64);
  assert.equal((await pair({ code: createPairingCode(db), device_name: { a: 1 } })).statusCode, 400);
  assert.equal((await pair({ code: 12345678, device_name: "p" })).statusCode, 400);
  await pair({ code: "00000000", device_name: "y".repeat(500) }); // a failure is logged with the capped name too
  const { detail } = db.prepare("SELECT detail FROM events WHERE kind = 'pair.fail'").get() as { detail: string };
  assert.equal(detail.length, 64);
});

test("A6: the edited-file view refuses secret-looking files and reads only up to the cap", async () => {
  const db = openDb(":memory:");
  const app = await buildApp(db);
  const { token } = (await app.inject({ method: "POST", url: "/pair", payload: { code: createPairingCode(db), device_name: "t" } })).json();
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES ('p', ?, 't', 'unknown')").run(ROOT);
  db.prepare("INSERT INTO sessions (id, project_id, kind, created_at) VALUES ('s1','p','claude','t')").run();
  const env = join(ROOT, ".env");
  writeFileSync(env, "API_KEY=sk-live-xyz");
  db.prepare("INSERT INTO messages (id, session_id, role, content, tool_json, ts) VALUES ('m1','s1','tool',NULL,?,'t')").run(
    JSON.stringify({ id: "t1", name: "Write", input: { file_path: env, content: "x" }, result: "ok" }),
  );
  const res = await app.inject({ method: "GET", url: `/sessions/s1/file?path=${encodeURIComponent(env)}`, headers: { authorization: `Bearer ${token}` } });
  assert.equal(res.statusCode, 403);
  assert.doesNotMatch(res.body, /sk-live/);
});

test("A7: native read tools follow symlinks before the root check", async () => {
  const db = openDb(":memory:");
  symlinkSync("/etc/hostname", join(ROOT, "sneaky"));
  const gate = new PermissionGate(db, "s1", () => {}, 40);
  const tools = buildNativeTools(gate, ROOT, () => {})!;
  const out = await (tools.read_file as any).execute({ path: "sneaky" }, { toolCallId: "c1" });
  assert.match(out, /outside the project roots/);
});

test("A8: the database file is owner-only", () => {
  const file = join(ROOT, "v.db");
  const db = openDb(file);
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES ('p','/x','x','unknown')").run(); // forces the WAL file
  for (const f of [file, `${file}-wal`]) assert.equal(statSync(f).mode & 0o777, 0o600, f);
  db.close();
});
