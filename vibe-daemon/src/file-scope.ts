// Auto-mode file scope (security.md #7, user decision 2026-10-06). In Auto mode
// the gate approves tools without asking; for FILE tools that's only safe inside
// the user's project folders. A Read/Write/Edit/… whose path resolves outside
// every registered project (and outside Claude's own ~/.claude) falls back to
// asking the phone — so `~/.ssh`, `~/.config/vibe-daemon.env`, `/etc` are never
// read or written silently. Bash can't be contained this way; it isn't covered.

import { realpathSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, join, resolve, sep } from "node:path";
import type { DB } from "./db.js";

// Claude Code tool → the input field holding its path.
const FILE_TOOLS: Record<string, string> = {
  Read: "file_path",
  Write: "file_path",
  Edit: "file_path",
  MultiEdit: "file_path",
  NotebookEdit: "notebook_path",
  Glob: "path",
  Grep: "path",
};

// Canonical path with symlinks resolved, for paths that may not exist yet (a
// Write target): resolve the deepest existing ancestor and re-append the rest.
export function canonical(p: string): string {
  const abs = resolve(p);
  try {
    return realpathSync(abs);
  } catch {
    const parent = dirname(abs);
    return parent === abs ? abs : join(canonical(parent), basename(abs));
  }
}

export const inside = (p: string, dir: string) => p === dir || p.startsWith(dir.endsWith(sep) ? dir : dir + sep);

// True when the call may be auto-approved: not a file tool, or every path it
// names is inside an allowed dir. A non-string path field fails closed.
export function fileToolInScope(toolName: string, input: Record<string, unknown>, cwd: string, allowedDirs: string[]): boolean {
  const key = FILE_TOOLS[toolName];
  if (!key) return true;
  const paths: unknown[] = [input[key] ?? cwd]; // Glob/Grep default to cwd
  // An absolute Glob pattern searches wherever it points.
  if (toolName === "Glob" && typeof input.pattern === "string" && isAbsolute(input.pattern)) {
    paths.push(input.pattern.split(/[*?[{]/)[0] || "/");
  }
  const dirs = allowedDirs.map(canonical);
  return paths.every((raw) => typeof raw === "string" && dirs.some((d) => inside(canonical(resolve(cwd, raw)), d)));
}

// The session's allowed dirs: its own cwd, every registered project, ~/.claude.
export function autoScopeDirs(db: DB, cwd: string): string[] {
  // A worktree session is isolated (ADR 0022): its checkout and ~/.claude only —
  // not the parent project or siblings, so it can't silently edit the main tree.
  if (db.prepare("SELECT 1 FROM sessions WHERE worktree_path = ? LIMIT 1").get(cwd)) return [cwd, join(homedir(), ".claude")];
  const projects = (db.prepare("SELECT path FROM projects").all() as { path: string }[]).map((r) => r.path);
  return [cwd, ...projects, join(homedir(), ".claude")];
}
