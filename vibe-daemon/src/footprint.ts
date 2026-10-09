// Disk the daemon itself causes to grow (ADR 0026): Claude transcripts, the checkpoint
// backups that make rewind possible (ADR 0023), the SQLite DB + WAL, and session
// worktrees. None of these has a built-in cap, so the server-health view shows them and
// the monitor can alert when the total passes a setting.
//
// Pure Node (no shell-out), never follows symlinks, and bounded: a runaway tree stops at
// MAX_ENTRIES instead of stalling a request. Cached — /system is polled every few seconds.

import { lstatSync, readdirSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import type { DB } from "./db.js";

export type FootprintItem = { label: string; bytes: number; truncated?: boolean };

const MAX_ENTRIES = 500_000;
const TTL_MS = 5 * 60_000;

/** Total apparent bytes under `path` (file, or directory tree). Symlinks count as themselves. */
export function treeBytes(path: string, budget = { left: MAX_ENTRIES }): { bytes: number; truncated: boolean } {
  let bytes = 0;
  let truncated = false;
  const stack = [path];
  while (stack.length) {
    const p = stack.pop()!;
    if (budget.left-- <= 0) {
      truncated = true;
      break;
    }
    let st;
    try {
      st = lstatSync(p);
    } catch {
      continue; // vanished or unreadable — not our problem
    }
    if (st.isDirectory()) {
      try {
        for (const name of readdirSync(p)) stack.push(join(p, name));
      } catch {
        /* unreadable dir */
      }
    } else {
      bytes += st.size; // regular files and symlinks (the link itself, never its target)
    }
  }
  return { bytes, truncated };
}

export type FootprintSources = { claudeDir: string; dbFile: string };
const realSources = (): FootprintSources => ({
  claudeDir: join(process.env.CLAUDE_CONFIG_DIR ?? join(homedir(), ".claude")),
  dbFile: resolve(process.env.VIBE_DB ?? "vibe.db"),
});

function compute(db: DB, src: FootprintSources): FootprintItem[] {
  const item = (label: string, paths: string[]): FootprintItem => {
    const budget = { left: MAX_ENTRIES };
    let bytes = 0;
    let truncated = false;
    for (const p of paths) {
      const r = treeBytes(p, budget);
      bytes += r.bytes;
      truncated ||= r.truncated;
    }
    return { label, bytes, ...(truncated ? { truncated } : {}) };
  };
  const worktrees = (db.prepare("SELECT worktree_path FROM sessions WHERE worktree_path IS NOT NULL").all() as { worktree_path: string }[]).map(
    (r) => r.worktree_path,
  );
  return [
    item("Claude transcripts", [join(src.claudeDir, "projects")]),
    item("Rewind backups", [join(src.claudeDir, "file-history")]),
    item("Daemon database", [src.dbFile, `${src.dbFile}-wal`, `${src.dbFile}-shm`]),
    item("Session worktrees", worktrees),
  ];
}

const cache = new Map<string, { at: number; items: FootprintItem[] }>();
export function footprint(db: DB, src: FootprintSources = realSources(), now = Date.now()): FootprintItem[] {
  const key = `${src.claudeDir}|${src.dbFile}`;
  const hit = cache.get(key);
  if (hit && now - hit.at < TTL_MS) return hit.items;
  const items = compute(db, src);
  cache.set(key, { at: now, items });
  return items;
}
/** Tests only. */
export const _clearFootprintCache = (): void => cache.clear();

export const totalBytes = (items: FootprintItem[]): number => items.reduce((n, i) => n + i.bytes, 0);
