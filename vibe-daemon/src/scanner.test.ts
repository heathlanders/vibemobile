// Scanner verification (CLAUDE.md §4). Builds a throwaway dir tree, asserts type
// detection + git_branch parsing, and that upsertProjects is idempotent (rescan
// = same row count, refreshed fields, stable id). Filesystem-only, no network.

import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { openDb } from "./db.js";
import { scanProjects, upsertProjects } from "./scanner.js";

// A root with: a flutter+git project, a node project, and a non-project dir.
function fixtureRoot(): string {
  const root = mkdtempSync(join(tmpdir(), "vibe-scan-"));
  const flutter = join(root, "myapp");
  mkdirSync(join(flutter, ".git"), { recursive: true });
  writeFileSync(join(flutter, "pubspec.yaml"), "name: myapp\n");
  writeFileSync(join(flutter, ".git", "HEAD"), "ref: refs/heads/main\n");

  const node = join(root, "daemon");
  mkdirSync(node, { recursive: true });
  writeFileSync(join(node, "package.json"), "{}\n");

  mkdirSync(join(root, "notes")); // unknown type, no markers
  return root;
}

test("detects type and git branch", () => {
  const root = fixtureRoot();
  try {
    const byName = Object.fromEntries(scanProjects([root]).map((p) => [p.name, p]));
    assert.equal(byName.myapp.type, "flutter");
    assert.equal(byName.myapp.git_branch, "main");
    assert.equal(byName.daemon.type, "node");
    assert.equal(byName.daemon.git_branch, null);
    assert.equal(byName.notes, undefined, "no git, no marker → not a project");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("missing root is skipped, not fatal", () => {
  assert.deepEqual(scanProjects(["/no/such/root/here"]), []);
});

test("upsert is idempotent and keeps row ids stable", () => {
  const root = fixtureRoot();
  try {
    const db = openDb(":memory:");
    const first = upsertProjects(db, scanProjects([root])) as { id: string; path: string }[];
    assert.equal(first.length, 2);
    const idByPath = Object.fromEntries(first.map((r) => [r.path, r.id]));

    const second = upsertProjects(db, scanProjects([root])) as { id: string; path: string }[];
    assert.equal(second.length, 2); // no duplicates
    for (const r of second) assert.equal(r.id, idByPath[r.path]); // ids preserved
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("git worktree counts; VIBE_PROJECT_IGNORE hides a repo", () => {
  const root = fixtureRoot();
  const saved = process.env.VIBE_PROJECT_IGNORE;
  try {
    const wt = join(root, "app-wt");
    mkdirSync(wt);
    writeFileSync(join(wt, ".git"), "gitdir: /x/.git/worktrees/app-wt\n"); // worktree = .git FILE
    process.env.VIBE_PROJECT_IGNORE = "myapp, other";
    const names = scanProjects([root]).map((p) => p.name).sort();
    assert.deepEqual(names, ["app-wt", "daemon"]);
  } finally {
    if (saved === undefined) delete process.env.VIBE_PROJECT_IGNORE;
    else process.env.VIBE_PROJECT_IGNORE = saved;
    rmSync(root, { recursive: true, force: true });
  }
});

test("rescan prunes vanished / non-project rows, but never ones with sessions or prompts", () => {
  const root = fixtureRoot();
  try {
    const db = openDb(":memory:");
    upsertProjects(db, scanProjects([root]));
    const ins = (id: string, path: string) =>
      db.prepare("INSERT INTO projects (id, path, name, type) VALUES (?,?,?,'unknown')").run(id, path, id);
    ins("gone", join(root, "deleted-long-ago"));
    ins("junk", join(root, "notes")); // exists, but not a project
    ins("busy", join(root, "gone-with-session"));
    db.prepare("INSERT INTO sessions (id, project_id, kind, status, created_at) VALUES ('s1','busy','claude','stale','x')").run();
    ins("prompted", join(root, "gone-with-prompt"));
    db.prepare("INSERT INTO prompts (id, title, body, project_id, created_at, updated_at) VALUES ('pr1','t','b','prompted','x','x')").run();
    ins("noted", join(root, "gone-with-note"));
    db.prepare("INSERT INTO notes (id, project_id, text, created_at, updated_at) VALUES ('n1','noted','idea','x','x')").run();

    const rows = upsertProjects(db, scanProjects([root])) as { id: string; name: string }[];
    const ids = rows.map((r) => r.id);
    assert.ok(!ids.includes("gone") && !ids.includes("junk"), "pruned");
    assert.ok(
      ids.includes("busy") && ids.includes("prompted") && ids.includes("noted"),
      "kept: deleting would cascade their data",
    );
    assert.equal(db.prepare("SELECT COUNT(*) n FROM sessions").get()!.n, 1);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
