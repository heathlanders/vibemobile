// Nightly DB upkeep (proposal 69 R7): prune the audit log, VACUUM after a big
// prune, and back up with SQLite's online backup. The backup dir comes from
// VIBE_BACKUP_DIR (ops note); unset → no backup. Never a path under the repo.

import { chmodSync, mkdirSync, readdirSync, renameSync, rmSync } from "node:fs";
import { join } from "node:path";
import type { DB } from "./db.js";

const DAY_MS = 86_400_000;
const KEEP_EVENTS_DAYS = 90;
const KEEP_NOISY_DAYS = 7; // high-volume, low-value kinds
// Not permission.auto_allow: those rows are the only record of what ran with no
// human approving it, so they keep the full 90 days like every other decision.
const NOISY_KINDS = ["projects.scan"];
const VACUUM_AFTER_ROWS = 50_000;
const KEEP_BACKUPS = 7;
const BACKUP_NAME = /^vibe-\d{4}-\d{2}-\d{2}\.db$/;

export type MaintenanceResult = { pruned: number; vacuumed: boolean; backup: string | null; backupDone: Promise<void> };

export function runMaintenance(db: DB, opts: { backupDir?: string; now?: Date }): MaintenanceResult {
  const now = opts.now ?? new Date();
  const before = (days: number) => new Date(now.getTime() - days * DAY_MS).toISOString();
  const marks = NOISY_KINDS.map(() => "?").join(",");
  const pruned =
    db.prepare("DELETE FROM events WHERE ts < ?").run(before(KEEP_EVENTS_DAYS)).changes +
    db.prepare(`DELETE FROM events WHERE kind IN (${marks}) AND ts < ?`).run(...NOISY_KINDS, before(KEEP_NOISY_DAYS)).changes;
  const vacuumed = pruned >= VACUUM_AFTER_ROWS;
  if (vacuumed) db.exec("VACUUM");

  if (!opts.backupDir) return { pruned, vacuumed, backup: null, backupDone: Promise.resolve() };
  const dir = opts.backupDir;
  const backup = join(dir, `vibe-${now.toISOString().slice(0, 10)}.db`);
  // A backup holds token hashes and full transcripts: owner-only. Written to a temp
  // name and renamed on success, so a failed run never replaces a good backup or
  // leaves a partial file that counts as one of the kept seven.
  const tmp = `${backup}.tmp`;
  const backupDone = (async () => {
    mkdirSync(dir, { recursive: true, mode: 0o700 }); // an existing dir keeps its mode: it may be shared
    try {
      await db.backup(tmp);
      chmodSync(tmp, 0o600);
      renameSync(tmp, backup);
    } catch (err) {
      rmSync(tmp, { force: true });
      throw err;
    }
    const ours = readdirSync(dir).filter((f) => BACKUP_NAME.test(f)).sort(); // ISO dates sort by age
    for (const f of ours.slice(0, -KEEP_BACKUPS)) rmSync(join(dir, f), { force: true });
  })();
  return { pruned, vacuumed, backup, backupDone };
}

// Run at the next 03:30 local time, then daily. unref'd: never keeps the process alive.
export function startMaintenance(db: DB, backupDir = process.env.VIBE_BACKUP_DIR): () => void {
  const next = new Date();
  next.setHours(3, 30, 0, 0);
  if (next.getTime() <= Date.now()) next.setDate(next.getDate() + 1);
  let daily: NodeJS.Timeout | undefined;
  const run = () => {
    try {
      const r = runMaintenance(db, { backupDir });
      console.log(`[vibe-daemon] maintenance: pruned ${r.pruned} events${r.vacuumed ? ", vacuumed" : ""}${r.backup ? `, backup ${r.backup}` : ""}`);
      r.backupDone.catch((err) => console.error("[vibe-daemon] backup failed", err));
    } catch (err) {
      console.error("[vibe-daemon] maintenance failed", err);
    }
  };
  const first = setTimeout(() => {
    run();
    daily = setInterval(run, DAY_MS);
    daily.unref?.();
  }, next.getTime() - Date.now());
  first.unref?.();
  return () => {
    clearTimeout(first);
    if (daily) clearInterval(daily);
  };
}
