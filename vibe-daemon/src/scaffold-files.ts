// Scaffold file containment (proposal 17, security.md). A scaffold's files are
// client-editable, so their paths are untrusted: validated on store (scaffolds.ts)
// AND re-checked on write (projects.ts) — a stored row could predate a rule, and
// write is the moment a bad path actually escapes. Every path must stay inside
// the target dir; no absolute, no `..`, no symlink games (we only ever create).

import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, isAbsolute, join, normalize, resolve, sep } from "node:path";

export type ScaffoldFile = { path: string; body: string };

// Caps mirror the attachment limits (security.md #8): bound the write surface so
// a huge/maliciously-large scaffold can't fill the disk.
const MAX_FILES = 200;
const MAX_TOTAL_BYTES = 1_000_000; // 1 MB across all bodies

// True iff `rel` is a relative path that, normalized, stays within a parent dir.
// Rejects absolute paths and any `..` segment (leading or interior).
function isContainedRelative(rel: string): boolean {
  if (typeof rel !== "string" || rel.length === 0) return false;
  if (isAbsolute(rel)) return false;
  const norm = normalize(rel);
  if (norm === ".." || norm.startsWith(".." + sep) || norm.includes(sep + ".." + sep)) return false;
  if (norm.startsWith(sep)) return false; // absolute after normalize (e.g. leading /)
  return true;
}

// Returns an error string if the file set is invalid, else null. Used by both
// scaffold CRUD (store-time) and project create (write-time).
export function validateScaffoldFiles(files: unknown): string | null {
  if (!Array.isArray(files) || files.length === 0) return "files must be a non-empty array";
  if (files.length > MAX_FILES) return `too many files (max ${MAX_FILES})`;
  let total = 0;
  const seen = new Set<string>();
  for (const f of files as ScaffoldFile[]) {
    if (!f || typeof f.path !== "string" || typeof f.body !== "string") {
      return "each file needs string path and body";
    }
    if (!isContainedRelative(f.path)) return `unsafe path: ${f.path}`;
    const key = normalize(f.path);
    if (seen.has(key)) return `duplicate path: ${f.path}`;
    seen.add(key);
    total += Buffer.byteLength(f.body, "utf8");
    if (total > MAX_TOTAL_BYTES) return `scaffold too large (max ${MAX_TOTAL_BYTES} bytes)`;
  }
  return null;
}

// Token-substitute {{project_name}} / {{date}} in a body (proposal 17 decision).
function substitute(body: string, vars: { project_name: string; date: string }): string {
  return body.replace(/\{\{project_name\}\}/g, vars.project_name).replace(/\{\{date\}\}/g, vars.date);
}

// Write every scaffold file under `targetDir`, creating parent dirs. Re-asserts
// containment per file (defence-in-depth) and refuses to write outside targetDir.
// Caller guarantees targetDir itself is in-roots and freshly created.
export function writeScaffoldFiles(
  targetDir: string,
  files: ScaffoldFile[],
  vars: { project_name: string; date: string },
): void {
  const root = resolve(targetDir);
  for (const f of files) {
    if (!isContainedRelative(f.path)) throw new Error(`unsafe scaffold path: ${f.path}`);
    const abs = resolve(join(root, f.path));
    if (abs !== root && !abs.startsWith(root + sep)) throw new Error(`scaffold path escapes target: ${f.path}`);
    mkdirSync(dirname(abs), { recursive: true });
    writeFileSync(abs, substitute(f.body, vars), { encoding: "utf8", flag: "wx" }); // wx = fail if exists
  }
}
