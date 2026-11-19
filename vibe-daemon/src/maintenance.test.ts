// Proposal 69 R8 + R7: messages indexed by session; nightly prune, vacuum, backup.
import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import Database from "better-sqlite3";
import { openDb } from "./db.js";
import { runMaintenance } from "./maintenance.js";

const DAY = 86_400_000;
const ago = (days: number) => new Date(Date.now() - days * DAY).toISOString();

test("attach and tool-result lookups use a messages(session_id) index (R8)", () => {
  const db = openDb(":memory:");
  const plan = (sql: string) => (db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all("s1") as { detail: string }[]).map((r) => r.detail).join(" | ");
  assert.match(plan("SELECT id FROM messages WHERE session_id = ? ORDER BY ts"), /USING INDEX idx_messages_session/);
  assert.match(plan("SELECT id FROM messages WHERE session_id = ? AND role = 'tool' ORDER BY ts DESC LIMIT 1"), /USING INDEX idx_messages_session/);
});

test("prune drops old events, keeps recent ones; only projects.scan goes after 7 days (R7)", () => {
  const db = openDb(":memory:");
  const ins = db.prepare("INSERT INTO events (id, kind, device_id, detail, ts) VALUES (?,?,?,?,?)");
  ins.run("a", "device.paired", null, "", ago(100)); // > 90 days → gone
  ins.run("b", "device.paired", null, "", ago(30)); // kept
  ins.run("c", "permission.auto_allow", null, "", ago(30)); // unattended execution: the 90-day rule, kept
  ins.run("d", "projects.scan", null, "", ago(8)); // noisy, > 7 days → gone
  ins.run("e", "permission.auto_allow", null, "", ago(100)); // > 90 days → gone
  ins.run("f", "permission.allow", null, "", ago(30)); // a human decision: 90-day rule
  const r = runMaintenance(db, {});
  const left = (db.prepare("SELECT id FROM events ORDER BY id").all() as { id: string }[]).map((x) => x.id);
  assert.deepEqual(left, ["b", "c", "f"]);
  assert.equal(r.pruned, 3);
  assert.equal(r.backup, null, "no VIBE_BACKUP_DIR → no backup");
});

test("backup writes a valid DB into the configured dir and keeps the newest 7 (R7)", async () => {
  const dir = mkdtempSync(join(tmpdir(), "vibe-backup-"));
  try {
    for (let i = 1; i <= 8; i++) writeFileSync(join(dir, `vibe-2026-01-0${i}.db`), "old");
    writeFileSync(join(dir, "unrelated.txt"), "keep me");
    const db = openDb(":memory:");
    db.prepare("INSERT INTO projects (id, path, name, type) VALUES (?,?,?,?)").run("p1", "/x", "x", "unknown");
    const r = runMaintenance(db, { backupDir: dir, now: new Date("2026-11-19T03:30:00Z") });
    await r.backupDone;
    assert.equal(r.backup, join(dir, "vibe-2026-11-19.db"));
    const copy = new Database(r.backup!, { readonly: true });
    assert.equal((copy.prepare("SELECT COUNT(*) AS n FROM projects").get() as { n: number }).n, 1);
    copy.close();
    const files = readdirSync(dir).sort();
    assert.equal(files.filter((f) => f.startsWith("vibe-")).length, 7);
    assert.ok(!files.includes("vibe-2026-01-01.db") && !files.includes("vibe-2026-01-02.db"), "oldest go first");
    assert.ok(files.includes("unrelated.txt"), "only our own backups are pruned");
    assert.equal(statSync(r.backup!).mode & 0o777, 0o600, "a backup holds tokens and transcripts");
    assert.ok(!files.some((f) => f.endsWith(".tmp")), "no temp file left");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("a failed backup leaves the existing same-day backup intact (R7)", async () => {
  const dir = mkdtempSync(join(tmpdir(), "vibe-backup-"));
  try {
    const good = join(dir, "vibe-2026-11-19.db");
    writeFileSync(good, "good backup");
    const db = openDb(":memory:");
    const failing = Object.assign(Object.create(db), { backup: () => Promise.reject(new Error("disk full")) });
    const r = runMaintenance(failing, { backupDir: dir, now: new Date("2026-11-19T03:30:00Z") });
    await assert.rejects(r.backupDone, /disk full/);
    assert.equal(readFileSync(good, "utf8"), "good backup");
    assert.deepEqual(readdirSync(dir), ["vibe-2026-11-19.db"], "no partial or temp file");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("a big prune on a real WAL file vacuums (R7)", () => {
  const dir = mkdtempSync(join(tmpdir(), "vibe-vacuum-"));
  try {
    const db = openDb(join(dir, "v.db"));
    const ins = db.prepare("INSERT INTO events (id, kind, device_id, detail, ts) VALUES (?,?,?,?,?)");
    const old = ago(100);
    db.transaction(() => {
      for (let i = 0; i < 50_000; i++) ins.run(`e${i}`, "device.paired", null, "", old);
    })();
    const r = runMaintenance(db, {});
    assert.equal(r.pruned, 50_000);
    assert.equal(r.vacuumed, true);
    db.close();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
