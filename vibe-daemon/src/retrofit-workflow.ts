// Retrofit the work standard (ADR 0028, docs/WORKFLOW.md) onto existing projects — ADDITIVELY.
// Lists which standard files each project lacks; with --apply it creates ONLY the missing ones
// (never overwrites, never edits an existing file) from the Foundations scaffold.
//
//   tsx src/retrofit-workflow.ts                 # report, writes nothing
//   tsx src/retrofit-workflow.ts --apply a b     # create missing files in projects named a, b

import { existsSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import Database from "better-sqlite3";
import { FOUNDATIONS_FILES, type ScaffoldFile } from "./scaffold-seed.js";
import { writeScaffoldFiles } from "./scaffold-files.js";

export type Retrofit = { missing: ScaffoldFile[]; notes: string[] };

// Pure over the filesystem: what a project dir lacks (no writes).
export function planRetrofit(dir: string): Retrofit {
  // A .gitkeep only exists to keep an empty dir in git: not "missing" if the dir is already there.
  const missing = FOUNDATIONS_FILES.filter((f) =>
    f.path.endsWith("/.gitkeep") ? !existsSync(join(dir, f.path.slice(0, -"/.gitkeep".length))) : !existsSync(join(dir, f.path)),
  );
  const notes: string[] = [];
  const plan = join(dir, "PLAN.md");
  if (existsSync(plan) && !/milestones/i.test(readFileSync(plan, "utf8"))) {
    notes.push("PLAN.md has no Milestones section (left unchanged — add one by hand or ask a session)");
  }
  return { missing, notes };
}

export function applyRetrofit(dir: string, name: string, missing: ScaffoldFile[], date = new Date().toISOString().slice(0, 10)): number {
  for (const f of missing) writeScaffoldFiles(dir, [f], { project_name: name, date }); // wx: still refuses to overwrite
  return missing.length;
}

if (process.argv[1]?.endsWith("retrofit-workflow.ts")) {
  const args = process.argv.slice(2);
  const apply = args[0] === "--apply";
  const only = new Set(apply ? args.slice(1) : []);
  const db = new Database(process.env.VIBE_DB ?? "vibe.db", { readonly: true });
  const projects = db.prepare("SELECT name, path FROM projects ORDER BY name").all() as { name: string; path: string }[];
  for (const p of projects) {
    if (!existsSync(p.path) || !statSync(p.path).isDirectory()) {
      console.log(`${p.name}: directory missing — skipped`);
      continue;
    }
    const r = planRetrofit(p.path);
    const label = r.missing.length ? `missing ${r.missing.length}: ${r.missing.map((f) => f.path).join(", ")}` : "complete";
    console.log(`${p.name}: ${label}${r.notes.map((n) => `\n    note: ${n}`).join("")}`);
    if (apply && only.has(p.name) && r.missing.length) console.log(`    -> created ${applyRetrofit(p.path, p.name, r.missing)} file(s)`);
  }
  if (apply) {
    const known = new Set(projects.map((p) => p.name));
    for (const n of only) if (!known.has(n)) console.log(`(no project named ${n})`);
  }
}
