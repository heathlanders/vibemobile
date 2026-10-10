// Project scanner (PLAN §1, §3). Lists immediate child dirs of the configured
// roots, detects project type from a marker file, and reads the git branch
// straight from .git/HEAD — no shell-out, so this adds no child-process surface
// (docs/security.md). upsertProjects() syncs the rows by unique `path`, leaving
// existing ids (referenced by sessions) intact.
//
// Only real projects are listed: a git checkout (`.git` dir or worktree file) or a
// dir with a marker file. Scratch dirs, Downloads, SDKs without git… are skipped.
// VIBE_PROJECT_IGNORE (comma-separated dir names) hides repos that aren't the
// user's projects (e.g. a Flutter SDK checkout).

import { randomUUID } from "node:crypto";
import { homedir } from "node:os";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { basename, join } from "node:path";
import type { DB } from "./db.js";

export type Project = {
  path: string;
  name: string;
  type: "flutter" | "laravel" | "node" | "unknown";
  git_branch: string | null;
  last_active: string; // ISO
};

// Marker file → type. First match wins.
const MARKERS: ReadonlyArray<readonly [string, Project["type"]]> = [
  ["pubspec.yaml", "flutter"],
  ["composer.json", "laravel"],
  ["package.json", "node"],
];

function has(dir: string, file: string): boolean {
  try {
    statSync(join(dir, file));
    return true;
  } catch {
    return false;
  }
}

// Parse the current branch from .git/HEAD ("ref: refs/heads/<branch>"). Detached
// HEAD or no git → null. Returns [branch, headMtimeMs|null] so the caller can
// fold the HEAD mtime into last_active without a second stat.
function gitBranch(dir: string): [string | null, number | null] {
  const head = join(dir, ".git", "HEAD");
  try {
    const mtime = statSync(head).mtimeMs;
    const m = /^ref:\s+refs\/heads\/(.+)$/m.exec(readFileSync(head, "utf8"));
    return [m ? m[1].trim() : null, mtime];
  } catch {
    return [null, null];
  }
}

const ignored = () =>
  new Set((process.env.VIBE_PROJECT_IGNORE ?? "").split(",").map((s) => s.trim()).filter(Boolean));

export function isProject(dir: string): boolean {
  return has(dir, ".git") || MARKERS.some(([f]) => has(dir, f));
}

// One dir's catalog entry (type, branch, activity), whether or not it qualifies.
export function projectAt(path: string): Project {
  const type = MARKERS.find(([f]) => has(path, f))?.[1] ?? "unknown";
  const [branch, headMtime] = gitBranch(path);
  const last = Math.max(statSync(path).mtimeMs, headMtime ?? 0);
  return { path, name: basename(path), type, git_branch: branch, last_active: new Date(last).toISOString() };
}

export function scanProjects(roots: string[]): Project[] {
  const skip = ignored();
  const out: Project[] = [];
  for (const root of roots) {
    let entries: import("node:fs").Dirent[];
    try {
      entries = readdirSync(root, { withFileTypes: true });
    } catch {
      continue; // missing/unreadable root → skip, don't crash the scan
    }
    for (const e of entries) {
      if (!e.isDirectory() || e.name.startsWith(".") || skip.has(e.name)) continue;
      const path = join(root, e.name);
      if (!isProject(path)) continue;
      out.push(projectAt(path));
    }
  }
  return out;
}

// Insert-or-update by unique path. Existing rows keep their id; type/branch/
// last_active refresh on rescan. Returns the synced rows from the DB.
export function upsertProjects(db: DB, scanned: Project[]): unknown[] {
  const stmt = db.prepare(
    `INSERT INTO projects (id, path, name, type, git_branch, last_active)
     VALUES (?,?,?,?,?,?)
     ON CONFLICT(path) DO UPDATE SET
       name = excluded.name,
       type = excluded.type,
       git_branch = excluded.git_branch,
       last_active = excluded.last_active`,
  );
  // Rows the scan no longer finds (dir deleted, or not a project any more) go —
  // unless sessions, project prompts or notes hang off them: those cascade-delete
  // with the project, so such rows stay listed. Callers always pass a FULL root scan.
  const prune = db.prepare(
    `DELETE FROM projects WHERE path = ?
       AND NOT EXISTS (SELECT 1 FROM sessions WHERE project_id = projects.id)
       AND NOT EXISTS (SELECT 1 FROM prompts WHERE project_id = projects.id)
       AND NOT EXISTS (SELECT 1 FROM notes WHERE project_id = projects.id)`,
  );
  const tx = db.transaction((rows: Project[]) => {
    for (const p of rows) {
      stmt.run(randomUUID(), p.path, p.name, p.type, p.git_branch, p.last_active);
    }
    const found = new Set(rows.map((p) => p.path));
    for (const { path } of db.prepare("SELECT path FROM projects").all() as { path: string }[]) {
      if (!found.has(path)) prune.run(path);
    }
  });
  tx(scanned);
  return db
    .prepare("SELECT id, path, name, type, git_branch, last_active FROM projects ORDER BY last_active DESC")
    .all();
}

// Roots to scan — comma-separated VIBE_PROJECT_ROOTS, else the home directory.
export function projectRoots(): string[] {
  return (process.env.VIBE_PROJECT_ROOTS ?? homedir())
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
}
