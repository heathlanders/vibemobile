// Project creation (proposal 17). POST /projects: make a new dir under a project
// root, optionally drop in a scaffold's files, optionally `git init` + commit.
// This is the daemon's FIRST filesystem-write + git shell-out outside the
// PTY/SDK engines (security.md) — every input is validated and every path scoped
// to projectRoots() before anything touches disk.

import { execFile } from "node:child_process";
import { existsSync, mkdirSync, rmSync } from "node:fs";
import { join, resolve } from "node:path";
import { promisify } from "node:util";
import type { FastifyInstance } from "fastify";
import type { DB } from "./db.js";
import { logEvent, type Device } from "./auth.js";
import { pathInRoots } from "./paths.js";
import { projectAt, projectRoots, scanProjects, upsertProjects } from "./scanner.js";
import { validateScaffoldFiles, writeScaffoldFiles, type ScaffoldFile } from "./scaffold-files.js";
import { diskGuard } from "./settings.js";

const run = promisify(execFile);

// Name allowlist: a single path segment, no traversal, no leading dot, capped.
const NAME_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;

type CreateBody = { name?: string; root?: string; scaffold_id?: string; git?: boolean };

// git via execFile (array args, never a shell string) → no command injection.
// Commit is attributed to the paired device (proposal 17 decision) so the audit
// trail shows who created the project.
async function gitInit(dir: string, device: Device | null, hasFiles: boolean): Promise<void> {
  await run("git", ["init"], { cwd: dir });
  if (!hasFiles) return; // bare dir → nothing to stage; init-only so the repo exists
  const name = device?.name || "vibe-daemon";
  const email = `${device?.id || "vibe-daemon"}@vibe.local`;
  await run("git", ["add", "-A"], { cwd: dir });
  await run(
    "git",
    ["-c", `user.name=${name}`, "-c", `user.email=${email}`, "commit", "-m", "Initial scaffold"],
    { cwd: dir },
  );
}

export function registerProjectCreateRoute(app: FastifyInstance, db: DB): void {
  // Rate-limited: this writes to disk and shells out, unlike the read-only GET.
  app.post("/projects", { config: { rateLimit: { max: 10, timeWindow: "1 minute" } } }, async (req, reply) => {
    const { name, root, scaffold_id, git = true } = (req.body ?? {}) as CreateBody;
    const device = (req as { device?: Device }).device ?? null;

    if (!name || !NAME_RE.test(name)) {
      return reply.code(400).send({ error: "invalid name (allowed: letters, digits, . _ - ; max 64; no leading dot)" });
    }

    // Root defaults to the first configured root (where existing projects live);
    // if the client sends one it must be exactly an allowed root, not a subdir.
    const roots = projectRoots();
    const chosenRoot = root ? roots.find((r) => resolve(r) === resolve(root)) : roots[0];
    if (!chosenRoot) return reply.code(400).send({ error: "root not in VIBE_PROJECT_ROOTS" });

    const target = join(chosenRoot, name);
    if (!pathInRoots(target)) return reply.code(400).send({ error: "target path out of bounds" });
    if (existsSync(target)) return reply.code(409).send({ error: "a project with that name already exists" });
    const disk = diskGuard(db, chosenRoot); // setting disk.min_free_gb (ADR 0026)
    if (!disk.ok) return reply.code(507).send({ error: disk.message });

    // Resolve the scaffold (if any) and re-validate its files before any write.
    let files: ScaffoldFile[] = [];
    if (scaffold_id) {
      const row = db.prepare("SELECT files_json FROM scaffolds WHERE id = ?").get(scaffold_id) as
        | { files_json: string }
        | undefined;
      if (!row) return reply.code(404).send({ error: "scaffold not found" });
      files = JSON.parse(row.files_json) as ScaffoldFile[];
      const err = validateScaffoldFiles(files);
      if (err) return reply.code(400).send({ error: `scaffold invalid: ${err}` });
    }

    // Past validation → start writing. Roll back the dir on any failure so a
    // partial create never leaves an orphan half-project behind.
    try {
      mkdirSync(target, { recursive: false });
      writeScaffoldFiles(target, files, { project_name: name, date: new Date().toISOString().slice(0, 10) });
      if (git) await gitInit(target, device, files.length > 0);
    } catch (e) {
      rmSync(target, { recursive: true, force: true });
      logEvent(db, "project.create.fail", device?.id ?? null, `${name}: ${(e as Error).message}`);
      return reply.code(500).send({ error: "create failed", detail: (e as Error).message });
    }

    // Sync the catalog (scanner detects type/branch) and return the new row.
    // A git-less create with no marker files isn't a "project" to the scanner;
    // list it anyway so the app can open it (a later rescan drops it again
    // unless it has sessions by then).
    const scanned = scanProjects(roots);
    if (!scanned.some((p) => resolve(p.path) === resolve(target))) scanned.push(projectAt(target));
    const rows = upsertProjects(db, scanned) as { path: string }[];
    const created = rows.find((r) => resolve(r.path) === resolve(target));
    logEvent(db, "project.create", device?.id ?? null, target);
    return reply.code(201).send(created);
  });
}
