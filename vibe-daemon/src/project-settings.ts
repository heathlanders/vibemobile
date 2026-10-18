// Per-project settings (ADR 0032 §5). Today: the merge queue's test command.
//
// It is set only from a paired device (these routes sit behind the global bearer gate),
// is audited, is never read from the repo and is not exposed through any peer tool. It
// runs agent-written test code, so the command line itself is held to an allowlist:
// an argv array (no shell), argv[0] a bare runner name from a fixed set that resolves,
// on a fixed PATH, to an executable OUTSIDE the project root.

import { accessSync, constants, realpathSync, statSync } from "node:fs";
import { isAbsolute, join } from "node:path";
import type { FastifyInstance } from "fastify";
import type { DB } from "./db.js";
import { logEvent, type Device } from "./auth.js";
import { canonical, inside } from "./file-scope.js";
import { pathInRoots } from "./paths.js";

export const RUNNERS: readonly string[] = ["npm", "pnpm", "yarn", "node", "npx", "dart", "flutter", "cargo", "make", "pytest", "python3", "go"];
export const MAX_ARGC = 32;
export const MAX_ARG_LEN = 256;

// The PATH runners are found on, and the PATH the test process gets. Never the repo's.
export const runnerPath = (): string => process.env.VIBE_TEST_PATH ?? "/usr/local/bin:/usr/bin:/bin";

export type Runner = { ok: true; path: string } | { ok: false; error: string };

// Absolute path of `name` on runnerPath(), refused when it (or its symlink target) lies
// inside the project. Called when the command is set AND again when it runs.
export function resolveRunner(name: string, projectPath: string): Runner {
  if (!RUNNERS.includes(name)) return { ok: false, error: `test command: '${name}' is not an allowed runner` };
  const root = canonical(projectPath);
  for (const dir of runnerPath().split(":")) {
    if (!dir || !isAbsolute(dir)) continue;
    const cand = join(dir, name);
    try {
      if (!statSync(cand).isFile()) continue;
      accessSync(cand, constants.X_OK);
      const real = realpathSync(cand);
      if (inside(canonical(cand), root) || inside(real, root)) return { ok: false, error: "test command: the runner resolves inside the project" };
      return { ok: true, path: real };
    } catch {
      /* not here: keep looking */
    }
  }
  return { ok: false, error: `test command: '${name}' was not found on the runner PATH` };
}

export function validateTestCommand(v: unknown, projectPath: string): { ok: true; argv: string[] } | { ok: false; error: string } {
  if (!Array.isArray(v) || v.length === 0 || v.length > MAX_ARGC) {
    return { ok: false, error: `test command must be an array of 1-${MAX_ARGC} strings (no shell string)` };
  }
  for (const a of v) {
    if (typeof a !== "string" || a.length > MAX_ARG_LEN || a.includes("\0")) {
      return { ok: false, error: `test command arguments must be strings of at most ${MAX_ARG_LEN} chars, no NUL` };
    }
  }
  const argv = v as string[];
  if (!argv[0] || argv[0].includes("/") || argv[0].includes("\\")) return { ok: false, error: "test command: argv[0] must be a bare runner name" };
  const r = resolveRunner(argv[0], projectPath);
  return r.ok ? { ok: true, argv } : r;
}

// The stored argv, or null when none is set (or a hand-edited row is no longer a string array).
export function getTestCommand(db: DB, projectId: string): string[] | null {
  const row = db.prepare("SELECT test_command FROM project_settings WHERE project_id = ?").get(projectId) as
    | { test_command: string | null }
    | undefined;
  if (!row?.test_command) return null;
  try {
    const v = JSON.parse(row.test_command);
    return Array.isArray(v) && v.length && v.every((a) => typeof a === "string") ? v : null;
  } catch {
    return null;
  }
}

export function registerProjectSettingsRoutes(app: FastifyInstance, db: DB): void {
  const projectPath = (id: string): string | undefined =>
    (db.prepare("SELECT path FROM projects WHERE id = ?").get(id) as { path: string } | undefined)?.path;

  app.get("/projects/:id/settings", async (req, reply) => {
    const { id } = req.params as { id: string };
    if (!projectPath(id)) return reply.code(404).send({ error: "not found" });
    return { test_command: getTestCommand(db, id) };
  });

  app.put("/projects/:id/settings", async (req, reply) => {
    const { id } = req.params as { id: string };
    const path = projectPath(id);
    if (!path) return reply.code(404).send({ error: "not found" });
    if (!pathInRoots(path)) return reply.code(403).send({ error: "path out of bounds" });
    const b = (req.body ?? {}) as { test_command?: unknown };
    if (!("test_command" in b)) return reply.code(400).send({ error: "test_command required (an array of strings, or null)" });
    let stored: string | null = null;
    if (b.test_command !== null) {
      const v = validateTestCommand(b.test_command, path);
      if (!v.ok) return reply.code(400).send({ error: v.error });
      stored = JSON.stringify(v.argv);
    }
    db.prepare(
      `INSERT INTO project_settings (project_id, test_command, updated_at, updated_by) VALUES (?,?,?,?)
       ON CONFLICT(project_id) DO UPDATE SET test_command = excluded.test_command, updated_at = excluded.updated_at, updated_by = excluded.updated_by`,
    ).run(id, stored, new Date().toISOString(), (req as { device?: Device }).device?.id ?? null);
    logEvent(db, "project.settings", (req as { device?: Device }).device?.id ?? null, `${id}:test_command=${stored ? stored.slice(0, 200) : "null"}`);
    return { test_command: getTestCommand(db, id) };
  });
}
