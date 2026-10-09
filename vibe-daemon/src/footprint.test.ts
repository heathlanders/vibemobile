// Daemon-owned disk growth (footprint.ts, ADR 0026): measurement, caching, alert.

import test from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { openDb } from "./db.js";
import { buildApp } from "./app.js";
import { createPairingCode } from "./auth.js";
import { _clearFootprintCache, footprint, totalBytes, treeBytes } from "./footprint.js";
import { applySettings } from "./settings.js";
import { computeAlerts, snapshot, type Sources } from "./system.js";

const mk = (p: string, bytes: number) => {
  mkdirSync(join(p, ".."), { recursive: true });
  writeFileSync(p, Buffer.alloc(bytes, 1));
};

function fixture() {
  const root = mkdtempSync(join(tmpdir(), "vibe-fp-"));
  const claudeDir = join(root, "claude");
  mk(join(claudeDir, "projects", "a", "s1.jsonl"), 1000);
  mk(join(claudeDir, "projects", "a", "sub", "s2.jsonl"), 500);
  mk(join(claudeDir, "file-history", "h1", "v1"), 200);
  const dbFile = join(root, "vibe.db");
  mk(dbFile, 300);
  mk(`${dbFile}-wal`, 40);
  return { root, claudeDir, dbFile, src: { claudeDir, dbFile } };
}

test("treeBytes sums files recursively; a missing path is 0", () => {
  const f = fixture();
  assert.deepEqual(treeBytes(join(f.claudeDir, "projects")), { bytes: 1500, truncated: false });
  assert.deepEqual(treeBytes(join(f.root, "nope")), { bytes: 0, truncated: false });
  assert.equal(treeBytes(f.dbFile).bytes, 300, "a single file works too");
});

test("treeBytes never follows symlinks (a link to a huge tree counts as the link only)", () => {
  const f = fixture();
  const big = join(f.root, "big");
  mk(join(big, "x"), 1_000_000);
  symlinkSync(big, join(f.claudeDir, "projects", "link-to-big"));
  const { bytes } = treeBytes(join(f.claudeDir, "projects"));
  assert.ok(bytes < 2000, `symlink target must not be walked, got ${bytes}`);
  // a symlink loop cannot hang it either
  symlinkSync(join(f.claudeDir, "projects"), join(f.claudeDir, "projects", "a", "loop"));
  assert.ok(treeBytes(join(f.claudeDir, "projects")).bytes < 2000);
});

test("treeBytes stops at its entry budget and says so", () => {
  const f = fixture();
  const r = treeBytes(join(f.claudeDir, "projects"), { left: 2 });
  assert.equal(r.truncated, true);
});

test("footprint: four labelled items; DB includes WAL; worktrees come from the sessions table", () => {
  _clearFootprintCache();
  const f = fixture();
  const db = openDb(":memory:");
  const wt = join(f.root, "wt1");
  mk(join(wt, "a.txt"), 70);
  mk(join(wt, "d", "b.txt"), 30);
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES ('p','/tmp','p','unknown')").run();
  db.prepare("INSERT INTO sessions (id, project_id, kind, status, created_at, worktree_path) VALUES ('s','p','claude','live',?,?)").run(new Date().toISOString(), wt);
  const items = footprint(db, f.src, 1);
  assert.deepEqual(items.map((i) => [i.label, i.bytes]), [
    ["Claude transcripts", 1500],
    ["Rewind backups", 200],
    ["Daemon database", 340],
    ["Session worktrees", 100],
  ]);
  assert.equal(totalBytes(items), 2140);
});

test("footprint is cached for a few minutes, then re-measured", () => {
  _clearFootprintCache();
  const f = fixture();
  const db = openDb(":memory:");
  const first = footprint(db, f.src, 1_000);
  mk(join(f.claudeDir, "projects", "a", "new.jsonl"), 5000);
  assert.equal(footprint(db, f.src, 1_000 + 60_000)[0].bytes, first[0].bytes, "within the TTL: cached");
  assert.equal(footprint(db, f.src, 1_000 + 6 * 60_000)[0].bytes, first[0].bytes + 5000, "after the TTL: fresh");
});

test("computeAlerts: daemon-data alert over the limit, names the biggest item; quiet under it or when off", () => {
  const base = { mem: { total: 100, available: 90, swapTotal: 0, swapFree: 0 }, disks: [], gpus: [] as any[] };
  const items = [
    { label: "Claude transcripts", bytes: 6e9 },
    { label: "Rewind backups", bytes: 1e9 },
  ];
  const over = computeAlerts(base, 90, { items, limitGb: 5 });
  assert.deepEqual(over.map((a) => a.key), ["daemon-data"]);
  assert.match(over[0].message, /7\.0 GB \(mostly claude transcripts\)/);
  assert.deepEqual(computeAlerts(base, 90, { items, limitGb: 10 }), [], "under the limit");
  assert.deepEqual(computeAlerts(base, 90, { items, limitGb: 0 }), [], "0 = off");
  assert.deepEqual(computeAlerts(base, 90), [], "no data supplied");
});

const quiet: Sources = {
  read: () => "",
  list: () => [],
  statfs: () => null,
  run: async () => "",
  sleep: async () => {},
};

test("snapshot carries the footprint and raises the alert once the setting is exceeded", async () => {
  _clearFootprintCache();
  const f = fixture();
  const db = openDb(":memory:");
  const calm = await snapshot(quiet, { db, dataSrc: f.src });
  assert.equal(calm.footprint.length, 4);
  assert.ok(!calm.alerts.some((a) => a.key === "daemon-data"), "~2 KB is far under the 5 GB default");

  applySettings(db, { "disk.daemon_data_alert_gb": 0.000001 }, null); // 1 KB — the fixture is ~2 KB
  _clearFootprintCache();
  const loud = await snapshot(quiet, { db, dataSrc: f.src });
  const a = loud.alerts.find((x) => x.key === "daemon-data");
  assert.ok(a, "alert raised");
  assert.match(a!.message, /mostly claude transcripts/);

  applySettings(db, { "disk.daemon_data_alert_gb": 0 }, null); // off
  assert.ok(!(await snapshot(quiet, { db, dataSrc: f.src })).alerts.some((x) => x.key === "daemon-data"));
});

test("GET /system exposes the footprint", async () => {
  _clearFootprintCache();
  const db = openDb(":memory:");
  const app = await buildApp(db);
  const { token } = (await app.inject({ method: "POST", url: "/pair", payload: { code: createPairingCode(db), device_name: "t" } })).json();
  const snap = (await app.inject({ method: "GET", url: "/system", headers: { authorization: `Bearer ${token}` } })).json();
  assert.deepEqual(snap.footprint.map((i: { label: string }) => i.label), ["Claude transcripts", "Rewind backups", "Daemon database", "Session worktrees"]);
  assert.ok(snap.footprint.every((i: { bytes: number }) => Number.isInteger(i.bytes) && i.bytes >= 0));
});
