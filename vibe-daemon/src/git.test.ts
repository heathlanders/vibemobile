// Read-only git status (ADR 0011, security.md #15). Runs against REAL temp git
// repos — same house style as pty-ws.test.ts spawning real tmux — because the
// thing under test is the shell-out itself.

import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { openDb } from "./db.js";
import { buildApp } from "./app.js";
import { createPairingCode } from "./auth.js";
import { gitStatus, parseStatus } from "./git.js";

const ROOT = mkdtempSync(join(tmpdir(), "vibe-git-"));
const OUTSIDE = mkdtempSync(join(tmpdir(), "vibe-gitout-"));
process.env.VIBE_PROJECT_ROOTS = ROOT;

const git = (cwd: string, ...args: string[]) => execFileSync("git", args, { cwd, stdio: "pipe" });

// A real repo with one commit and one dirty file, plus a plain (non-repo) dir.
const REPO = join(ROOT, "repo");
const PLAIN = join(ROOT, "plain");
mkdirSync(REPO);
mkdirSync(PLAIN);
git(REPO, "init", "-b", "main");
writeFileSync(join(REPO, "a.txt"), "one\n");
git(REPO, "add", "-A");
git(REPO, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "init");
writeFileSync(join(REPO, "a.txt"), "two\n");
writeFileSync(join(REPO, "untracked.txt"), "x\n");

async function setup() {
  const db = openDb(":memory:");
  const app = await buildApp(db);
  const { token } = (
    await app.inject({ method: "POST", url: "/pair", payload: { code: createPairingCode(db), device_name: "t" } })
  ).json();
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES (?,?,?,?)").run("p", REPO, "repo", "unknown");
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES (?,?,?,?)").run("pplain", PLAIN, "plain", "unknown");
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES (?,?,?,?)").run("pout", OUTSIDE, "out", "unknown");
  return { db, app, auth: { authorization: `Bearer ${token}` } };
}

const get = (app: any, auth: any, url: string) => app.inject({ method: "GET", url, headers: auth });

// ---- parsing --------------------------------------------------------------

test("parses branch, ahead/behind and file states", () => {
  const s = parseStatus("## main...origin/main [ahead 2, behind 3]\n M lib/a.dart\n?? new.txt\n");
  assert.equal(s.branch, "main");
  assert.equal(s.ahead, 2);
  assert.equal(s.behind, 3);
  assert.equal(s.clean, false);
  assert.deepEqual(
    s.files.map((f) => f.path),
    ["lib/a.dart", "new.txt"],
  );
});

test("a rename reports the new path", () => {
  const s = parseStatus("## main\nR  old.txt -> new.txt\n");
  assert.equal(s.files[0].path, "new.txt");
});

test("no changes is clean", () => {
  const s = parseStatus("## main...origin/main\n");
  assert.equal(s.clean, true);
  assert.equal(s.files.length, 0);
});

test("a huge status is capped and flagged, never silently cut", () => {
  const lines = ["## main", ...Array.from({ length: 300 }, (_, i) => ` M f${i}.txt`)].join("\n");
  const s = parseStatus(lines);
  assert.equal(s.files.length, 200);
  assert.equal(s.truncated, true);
});

// ---- real repos -----------------------------------------------------------

test("gitStatus reads a real dirty repo", async () => {
  const s = await gitStatus(REPO);
  assert.equal(s.repo, true);
  assert.equal(s.branch, "main");
  assert.equal(s.clean, false);
  const paths = s.files.map((f) => f.path).sort();
  assert.deepEqual(paths, ["a.txt", "untracked.txt"]);
});

test("a non-repo directory reports repo:false rather than failing", async () => {
  const s = await gitStatus(PLAIN);
  assert.equal(s.repo, false);
  assert.equal(s.clean, true);
});

// ---- route ----------------------------------------------------------------

test("route returns the status of a project's repo", async () => {
  const { app, auth } = await setup();
  const res = await get(app, auth, "/projects/p/git-status");
  assert.equal(res.statusCode, 200);
  assert.equal(res.json().branch, "main");
});

test("route refuses a project outside VIBE_PROJECT_ROOTS", async () => {
  const { app, auth } = await setup();
  assert.equal((await get(app, auth, "/projects/pout/git-status")).statusCode, 403);
});

test("route 404s an unknown project", async () => {
  const { app, auth } = await setup();
  assert.equal((await get(app, auth, "/projects/nope/git-status")).statusCode, 404);
});

test("route requires a bearer token", async () => {
  const { app } = await setup();
  assert.equal((await app.inject({ method: "GET", url: "/projects/p/git-status" })).statusCode, 401);
});

test("push and the other remote/history-rewriting git routes do not exist (ADR 0024: no push)", async () => {
  const { app, auth } = await setup();
  for (const op of ["push", "pull", "fetch", "reset", "rebase", "merge", "remote", "clean", "stash"]) {
    for (const scope of ["/projects/p", "/sessions/s"]) {
      const res = await app.inject({ method: "POST", url: `${scope}/git/${op}`, headers: auth, payload: {} });
      assert.equal(res.statusCode, 404, `${scope}/git/${op} must not exist`);
    }
  }
});

// ---- ADR 0024 hardening: the agent can plant code in .git/config -------------

import { existsSync } from "node:fs";
import { gitEnv } from "./git-run.js";

function plantedRepo(name: string) {
  const dir = join(ROOT, name);
  mkdirSync(dir);
  git(dir, "init", "-b", "main");
  writeFileSync(join(dir, "a.txt"), "x\n");
  const marker = join(dir, "PWNED");
  const script = join(dir, "evil.sh");
  writeFileSync(script, `#!/bin/sh\ntouch "${marker}"\n`, { mode: 0o755 });
  git(dir, "config", "core.fsmonitor", script);
  return { dir, marker };
}

test("control: a planted core.fsmonitor DOES run under plain `git status`", () => {
  const { dir, marker } = plantedRepo("planted-control");
  execFileSync("git", ["status"], { cwd: dir, stdio: "pipe" });
  assert.ok(existsSync(marker), "test premise broken: the plant did not fire, so the next test proves nothing");
});

test("gitStatus does not execute a planted core.fsmonitor", async () => {
  const { dir, marker } = plantedRepo("planted");
  const st = await gitStatus(dir);
  assert.equal(st.repo, true);
  assert.equal(existsSync(marker), false);
});

test("gitEnv strips GIT_* from the inherited env and pins the safe ones", () => {
  const env = gitEnv({ PATH: "/bin", GIT_DIR: "/x", GIT_SSH_COMMAND: "evil", git_external_diff: "evil" });
  assert.equal(env.PATH, "/bin");
  assert.equal(env.GIT_DIR, undefined);
  assert.equal(env.GIT_SSH_COMMAND, undefined);
  assert.equal(env.git_external_diff, undefined);
  assert.equal(env.GIT_TERMINAL_PROMPT, "0");
  assert.equal(env.GIT_CONFIG_NOSYSTEM, "1");
  assert.equal(env.GIT_OPTIONAL_LOCKS, "0");
});
