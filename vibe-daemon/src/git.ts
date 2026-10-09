// Read-only git status for a project (ADR 0011, security.md #15).
//
// Scope discipline — this file is deliberately READ-ONLY. ADR 0006's git
// shell-out only ever ran in a freshly created, empty directory; this runs in a
// real repo with real history and the server's real remote credentials, which
// is a bigger blast radius. So the first pass ships status only: no commit, no
// push, no ref or remote name from the client, nothing that mutates.
//
// `scanner.ts` stays untouched — it is documented as no-shell-out by design and
// that guarantee is worth keeping; git lives here instead.
//
// Every invocation goes through `gitRun` (git-run.ts, ADR 0024): ARRAY args via
// execFile, repo-planted hooks/config neutralised, scrubbed env, a timeout and an
// output cap. cwd is scoped by pathInRoots in the route.

import type { FastifyInstance } from "fastify";
import type { DB } from "./db.js";
import { gitRun } from "./git-run.js";
import { pathInRoots } from "./paths.js";

const MAX_FILES = 200;

export type GitFile = { path: string; index: string; worktree: string };
export type GitStatus = {
  repo: boolean;
  branch: string | null;
  ahead: number;
  behind: number;
  clean: boolean;
  files: GitFile[];
  truncated: boolean;
};

const NOT_A_REPO: GitStatus = {
  repo: false,
  branch: null,
  ahead: 0,
  behind: 0,
  clean: true,
  files: [],
  truncated: false,
};

// Parse `git status --porcelain=v1 -b` output. First line is the branch header:
//   ## main...origin/main [ahead 1, behind 2]
// Remaining lines are `XY path` (X = index, Y = worktree). Renames render as
// "old -> new"; we keep the new path, which is what the user cares about.
export function parseStatus(stdout: string): GitStatus {
  const lines = stdout.split("\n").filter((l) => l.length > 0);
  let branch: string | null = null;
  let ahead = 0;
  let behind = 0;
  const files: GitFile[] = [];
  let truncated = false;

  for (const line of lines) {
    if (line.startsWith("## ")) {
      const head = line.slice(3);
      branch = head.split("...")[0].split(" ")[0] || null;
      if (branch === "No" || head.startsWith("No commits yet")) {
        // "## No commits yet on main" — a fresh repo.
        branch = head.replace(/^No commits yet on /, "").split(" ")[0] || null;
      }
      ahead = Number(/ahead (\d+)/.exec(head)?.[1] ?? 0);
      behind = Number(/behind (\d+)/.exec(head)?.[1] ?? 0);
      continue;
    }
    if (files.length >= MAX_FILES) {
      truncated = true;
      continue; // keep scanning so the flag is honest, but collect no more
    }
    const path = line.slice(3);
    files.push({
      path: path.includes(" -> ") ? path.split(" -> ")[1] : path,
      index: line[0],
      worktree: line[1],
    });
  }
  return { repo: true, branch, ahead, behind, clean: files.length === 0 && !truncated, files, truncated };
}

export async function gitStatus(cwd: string): Promise<GitStatus> {
  try {
    const { stdout } = await gitRun(cwd, ["status", "--porcelain=v1", "-b"]);
    return parseStatus(stdout);
  } catch {
    // Not a repo, git missing, or the call timed out — all "no status to show".
    return NOT_A_REPO;
  }
}

export function registerGitRoutes(app: FastifyInstance, db: DB): void {
  app.get("/projects/:id/git-status", async (req, reply) => {
    const { id } = req.params as { id: string };
    const row = db.prepare("SELECT path FROM projects WHERE id = ?").get(id) as { path: string } | undefined;
    if (!row) return reply.code(404).send({ error: "not found" });
    if (!pathInRoots(row.path)) return reply.code(403).send({ error: "path out of bounds" });
    return gitStatus(row.path);
  });

  // Same read-only status, for a session's own checkout (its worktree if it has
  // one — ADR 0022). Still no mutation, still pathInRoots-scoped.
  app.get("/sessions/:id/git-status", async (req, reply) => {
    const { id } = req.params as { id: string };
    const row = db
      .prepare("SELECT COALESCE(s.worktree_path, p.path) AS path FROM sessions s JOIN projects p ON p.id = s.project_id WHERE s.id = ?")
      .get(id) as { path: string } | undefined;
    if (!row) return reply.code(404).send({ error: "not found" });
    if (!pathInRoots(row.path)) return reply.code(403).send({ error: "path out of bounds" });
    return gitStatus(row.path);
  });
}
