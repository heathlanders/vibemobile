// Proposal 69 R6: the audit log says WHAT ran, not just which tool.
import test from "node:test";
import assert from "node:assert/strict";
import { openDb } from "./db.js";
import { PermissionGate } from "./permission-gate.js";

const details = (db: ReturnType<typeof openDb>, kind: string) =>
  (db.prepare("SELECT detail FROM events WHERE kind = ? ORDER BY ts").all(kind) as { detail: string }[]).map((r) => r.detail);

test("auto-allowed Bash is audited with its command; file tools with their path", async () => {
  const db = openDb(":memory:");
  const gate = new PermissionGate(db, "s1", () => {}, 5000, "/proj");
  await gate.request("Bash", { command: "rm -rf build\n  && npm test" });
  await gate.request("Edit", { file_path: "/proj/a.ts", old_string: "x", new_string: "y" });
  await gate.request("WebFetch", { url: "https://example.com/x", prompt: "p" });
  assert.deepEqual(details(db, "permission.auto_allow"), [
    "s1:Bash:rm -rf build && npm test",
    "s1:Edit:/proj/a.ts",
    "s1:WebFetch:https://example.com/x",
  ]);
});

test("a human decision carries the command too, capped at 200 chars", async () => {
  const db = openDb(":memory:");
  const gate = new PermissionGate(db, "s1", () => {}, 5000, "/proj");
  gate.setAutoAllow(false);
  const long = "echo " + "a".repeat(400);
  const p = gate.request("Bash", { command: long }, { toolUseID: "tu1" });
  gate.onPermission("tu1", false, "dev-1");
  await p;
  const [d] = details(db, "permission.deny");
  assert.ok(d.startsWith("s1:Bash:echo aaa"));
  assert.equal(d.length, "s1:Bash:".length + 200);
});

test("a tool with nothing to summarize keeps the old detail", async () => {
  const db = openDb(":memory:");
  const gate = new PermissionGate(db, "s1", () => {}, 5000, "/proj");
  await gate.request("TodoWrite", { todos: [] });
  assert.deepEqual(details(db, "permission.auto_allow"), ["s1:TodoWrite"]);
});
