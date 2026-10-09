// Session-scoped file-name listing for the composer's `@file` autocomplete
// (proposal 22 phase 2b, ADR 0010, security.md #13).
//
// This is a NEW read surface and is deliberately the smallest one that works:
//
//  - session-scoped — the capability is the session's own project dir, so the
//    route can never browse a project the caller isn't already in;
//  - NAMES ONLY. Content still requires the edit-set capability
//    (`GET /sessions/:id/file`, file-edits.ts). Listing a name discloses far
//    less than serving bytes, and that split is the containment argument;
//  - pure `node:fs`, no shell-out (same stance as scanner.ts);
//  - symlinks are never followed — a symlink inside a root would otherwise
//    escape it;
//  - VCS/dependency/build dirs and all dotdirs are skipped, so `.git` objects
//    and `.env`-adjacent config never appear;
//  - hard caps with a visible `truncated` flag — no silent truncation.

import { readdirSync } from "node:fs";
import { join, relative, resolve } from "node:path";
import type { FastifyInstance } from "fastify";
import type { DB } from "./db.js";
import { logEvent, type Device } from "./auth.js";
import { pathInRoots } from "./paths.js";

// Directories never walked. Dotdirs (.git, .venv, …) are excluded separately.
const SKIP_DIRS = new Set(["node_modules", "build", "dist", "target", "vendor", "coverage"]);

const MAX_WALK = 5000; // entries visited before giving up
const MAX_RESULTS = 50;

export type TreeResult = { files: { relPath: string }[]; truncated: boolean };

/// Case-insensitive substring search over the file names under `root`.
/// `truncated` is true when the walk hit its cap or more matches existed than
/// `limit` — the client must surface it rather than imply full coverage.
export function walkFiles(root: string, query: string, limit: number): TreeResult {
  const base = resolve(root);
  const q = query.trim().toLowerCase();
  const files: { relPath: string }[] = [];
  const stack: string[] = [base];
  let walked = 0;
  let truncated = false;

  while (stack.length > 0) {
    const dir = stack.pop()!;
    let entries;
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch {
      continue; // unreadable dir — skip, never fail the whole listing
    }
    for (const e of entries) {
      if (++walked > MAX_WALK) return { files, truncated: true };
      if (e.isSymbolicLink()) continue; // never follow — a symlink escapes the root
      if (e.name.startsWith(".")) continue;
      const full = join(dir, e.name);
      if (e.isDirectory()) {
        if (!SKIP_DIRS.has(e.name)) stack.push(full);
        continue;
      }
      if (!e.isFile()) continue;
      const rel = relative(base, full);
      if (q !== "" && !rel.toLowerCase().includes(q)) continue;
      if (files.length >= limit) {
        truncated = true;
        continue; // keep walking so the count stays honest, but collect no more
      }
      files.push({ relPath: rel });
    }
  }
  return { files, truncated };
}

export function registerProjectTreeRoute(app: FastifyInstance, db: DB): void {
  app.get(
    "/sessions/:id/tree",
    { config: { rateLimit: { max: 30, timeWindow: "1 minute" } } },
    async (req, reply) => {
      const { id } = req.params as { id: string };
      const { q = "", limit } = req.query as { q?: string; limit?: string };

      const row = db
        .prepare("SELECT COALESCE(s.worktree_path, p.path) AS path FROM sessions s LEFT JOIN projects p ON p.id = s.project_id WHERE s.id = ?")
        .get(id) as { path: string | null } | undefined;
      if (row === undefined) return reply.code(404).send({ error: "not found" });
      const root = row.path;
      if (!root) return reply.code(404).send({ error: "session has no project" });
      if (!pathInRoots(root)) return reply.code(403).send({ error: "path out of bounds" });

      const cap = Math.min(Number(limit) || MAX_RESULTS, MAX_RESULTS);
      const result = walkFiles(root, q, cap);
      logEvent(db, "session.tree", (req as { device?: Device }).device?.id ?? null, `${id}:${q.slice(0, 64)}`);
      return { root, ...result };
    },
  );
}
