// security.md #7: Auto mode only auto-approves file tools inside project folders.
import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { openDb } from "./db.js";
import { PermissionGate } from "./permission-gate.js";
import { autoScopeDirs, canonical, fileToolInScope } from "./file-scope.js";

const root = mkdtempSync(join(tmpdir(), "scope-"));
const proj = join(root, "proj");
const other = join(root, "other");
const secret = join(root, "secret");
for (const d of [proj, other, secret]) mkdirSync(d);
writeFileSync(join(secret, "key"), "x");
symlinkSync(secret, join(proj, "link")); // a link inside the project pointing out
const dirs = [proj, other];

test("fileToolInScope: inside / outside / relative / symlink / new file / non-file tools", () => {
  const ok = (tool: string, input: Record<string, unknown>) => fileToolInScope(tool, input, proj, dirs);
  assert.equal(ok("Read", { file_path: join(proj, "a.ts") }), true);
  assert.equal(ok("Read", { file_path: "src/a.ts" }), true, "relative → cwd");
  assert.equal(ok("Read", { file_path: join(other, "x") }), true, "another registered project");
  assert.equal(ok("Read", { file_path: join(secret, "key") }), false);
  assert.equal(ok("Read", { file_path: "../secret/key" }), false, "traversal");
  assert.equal(ok("Read", { file_path: join(proj, "link", "key") }), false, "symlink resolved");
  assert.equal(ok("Write", { file_path: join(proj, "new", "deep", "f.ts") }), true, "not-yet-existing file inside");
  assert.equal(ok("Write", { file_path: "/etc/cron.d/x" }), false);
  assert.equal(ok("NotebookEdit", { notebook_path: join(secret, "n.ipynb") }), false);
  assert.equal(ok("Grep", { pattern: "TODO" }), true, "default path = cwd");
  assert.equal(ok("Grep", { pattern: "x", path: secret }), false);
  assert.equal(ok("Glob", { pattern: `${secret}/**/*` }), false, "absolute glob pattern");
  assert.equal(ok("Glob", { pattern: "**/*.ts" }), true);
  assert.equal(ok("Read", { file_path: 42 }), false, "non-string fails closed");
  assert.equal(ok("Bash", { command: "cat /etc/passwd" }), true, "not a file tool (Bash isn't covered)");
  assert.equal(canonical(join(proj, "link")), canonical(secret));
});

test("autoScopeDirs: cwd + every registered project + ~/.claude", () => {
  const db = openDb(":memory:");
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES ('p1', ?, 'o', 'unknown')").run(other);
  const d = autoScopeDirs(db, proj);
  assert.equal(d[0], proj);
  assert.ok(d.includes(other));
  assert.ok(d.some((x) => x.endsWith("/.claude")));
});

test("gate: Auto approves in-scope file calls, asks for out-of-scope ones (audited)", async () => {
  const db = openDb(":memory:");
  const frames: any[] = [];
  const gate = new PermissionGate(db, "s1", (f) => frames.push(f), 50, proj, () => {}, (t, i) => fileToolInScope(t, i, proj, dirs));
  assert.equal(gate.autoAllowOn, true);
  assert.equal((await gate.request("Read", { file_path: join(proj, "a") })).behavior, "allow");
  assert.equal(frames.length, 0, "no prompt in scope");

  const out = gate.request("Read", { file_path: join(secret, "key") }, { toolUseID: "tu1" });
  assert.equal(frames[0]?.t, "permission_request", "asked even though Auto is on");
  gate.onPermission("tu1", true, "dev1");
  assert.equal((await out).behavior, "allow");
  const kinds = (db.prepare("SELECT kind FROM events ORDER BY rowid").all() as any[]).map((e) => e.kind);
  assert.deepEqual(kinds, ["permission.auto_allow", "permission.out_of_scope", "permission.allow"]);
});
