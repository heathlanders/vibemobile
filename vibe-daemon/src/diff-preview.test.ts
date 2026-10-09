// Diff preview on permission_request (proposal 02). The load-bearing property:
// the preview is derived from the SAME input object the gate resolves as
// updatedInput — render must equal execution.

import test from "node:test";
import assert from "node:assert/strict";
import { openDb } from "./db.js";
import { previewForTool } from "./diff-preview.js";
import { PermissionGate } from "./permission-gate.js";

// ---- previewForTool -------------------------------------------------------

test("Edit renders a unified diff with a project-relative path", () => {
  const p = previewForTool(
    "Edit",
    { file_path: "/proj/lib/a.dart", old_string: "one", new_string: "two" },
    "/proj",
  )!;
  assert.equal(p.relPath, "lib/a.dart");
  assert.equal(p.adds, 1);
  assert.equal(p.dels, 1);
  assert.ok(p.diff.includes("-one"));
  assert.ok(p.diff.includes("+two"));
  assert.equal(p.truncated, false);
});

test("Write renders as all-additions", () => {
  const p = previewForTool("Write", { file_path: "/proj/new.txt", content: "l1\nl2\n" }, "/proj")!;
  assert.equal(p.relPath, "new.txt");
  assert.equal(p.adds, 2);
  assert.equal(p.dels, 0);
  assert.deepEqual(p.diff.split("\n"), ["+l1", "+l2"]);
});

test("MultiEdit combines its edits into one preview", () => {
  const p = previewForTool(
    "MultiEdit",
    {
      file_path: "/proj/a.dart",
      edits: [
        { old_string: "a", new_string: "b" },
        { old_string: "c", new_string: "d" },
      ],
    },
    "/proj",
  )!;
  assert.equal(p.adds, 2);
  assert.equal(p.dels, 2);
});

test("non-file tools and pathless inputs get no preview", () => {
  assert.equal(previewForTool("Bash", { command: "rm -rf /" }, "/proj"), null);
  assert.equal(previewForTool("Read", { file_path: "/proj/a.dart" }, "/proj"), null);
  assert.equal(previewForTool("Edit", { old_string: "a", new_string: "b" }, "/proj"), null);
});

test("a path outside the cwd keeps its absolute form", () => {
  const p = previewForTool("Write", { file_path: "/etc/hosts", content: "x" }, "/proj")!;
  assert.equal(p.relPath, "/etc/hosts");
});

test("an oversized edit is cut with a visible marker, never silently", () => {
  const big = Array.from({ length: 900 }, (_, i) => `line ${i}`).join("\n");
  const p = previewForTool("Write", { file_path: "/proj/big.txt", content: big }, "/proj")!;
  assert.equal(p.truncated, true);
  assert.ok(p.diff.includes("lines truncated"), "the cut must be visible in the diff text");
  assert.equal(p.adds, 900, "counts describe the whole edit, not the shown slice");
});

// ---- gate integration -----------------------------------------------------

const seedDb = () => openDb(":memory:");

test("gate attaches diffPreview to an Edit request and allows the same input back", async () => {
  const db = seedDb();
  const frames: any[] = [];
  const gate = new PermissionGate(db, "s1", (f) => frames.push(f), 5000, "/proj");
  gate.setAutoAllow(false);

  const input = { file_path: "/proj/lib/a.dart", old_string: "one", new_string: "two" };
  const decision = gate.request("Edit", input, { toolUseID: "tu1" });

  const req = frames.find((f) => f.t === "permission_request");
  assert.ok(req, "a request frame is sent");
  assert.equal(req.diffPreview.relPath, "lib/a.dart");
  assert.ok(req.diffPreview.diff.includes("+two"));

  gate.onPermission("tu1", true);
  const d = (await decision) as any;
  assert.equal(d.behavior, "allow");
  // Render == execution: the approved input is the very object we previewed.
  assert.equal(d.updatedInput, input);
});

test("gate omits diffPreview for non-file tools", async () => {
  const db = seedDb();
  const frames: any[] = [];
  const gate = new PermissionGate(db, "s1", (f) => frames.push(f), 5000, "/proj");
  gate.setAutoAllow(false);

  const decision = gate.request("Bash", { command: "ls" }, { toolUseID: "tu2" });
  const req = frames.find((f) => f.t === "permission_request");
  assert.equal(req.diffPreview, undefined);

  gate.onPermission("tu2", false);
  assert.equal(((await decision) as any).behavior, "deny");
});

test("the answering device is recorded on the decision (security.md #5)", async () => {
  const db = seedDb();
  const gate = new PermissionGate(db, "s1", () => {}, 5000, "/proj");
  gate.setAutoAllow(false);

  const allowed = gate.request("Bash", { command: "ls" }, { toolUseID: "tu-a" });
  gate.onPermission("tu-a", true, "dev-1");
  await allowed;
  const denied = gate.request("Bash", { command: "rm -rf /" }, { toolUseID: "tu-d" });
  gate.onPermission("tu-d", false, "dev-1");
  await denied;

  const rows = db
    .prepare("SELECT kind, device_id FROM events WHERE kind LIKE 'permission.%' ORDER BY ts")
    .all() as any[];
  assert.deepEqual(
    rows.map((r) => [r.kind, r.device_id]),
    [
      ["permission.allow", "dev-1"],
      ["permission.deny", "dev-1"],
    ],
  );
});

test("an auto-allow approval has no device — it is not a human decision", async () => {
  const db = seedDb();
  const gate = new PermissionGate(db, "s1", () => {}, 5000, "/proj");
  await gate.request("Read", { file_path: "/proj/a" }, { toolUseID: "tu-auto" });
  const row = db.prepare("SELECT kind, device_id FROM events").get() as any;
  assert.equal(row.kind, "permission.auto_allow");
  assert.equal(row.device_id, null);
});

test("replayed requests keep their preview (reattach mid-approval)", async () => {
  const db = seedDb();
  const gate = new PermissionGate(db, "s1", () => {}, 5000, "/proj");
  gate.setAutoAllow(false);
  const decision = gate.request("Write", { file_path: "/proj/a.txt", content: "hi" }, { toolUseID: "tu3" });

  const replayed: any[] = [];
  gate.replay((f) => replayed.push(f));
  assert.equal(replayed.length, 1);
  assert.equal(replayed[0].diffPreview.relPath, "a.txt");

  gate.onPermission("tu3", true);
  await decision;
});
