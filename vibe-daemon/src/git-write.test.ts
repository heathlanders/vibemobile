// Git write surface (ADR 0024): stage / commit / branch, project- and session-scoped.
// Real temp repos — the shell-out is the thing under test. Heavy on hostile input:
// option injection, traversal, secrets, and code the AGENT can plant in .git.

import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { openDb } from "./db.js";
import { buildApp } from "./app.js";
import { createPairingCode } from "./auth.js";
import { checkStagePath, isSensitivePath, validBranchName, validCommitMessage } from "./git-write.js";

const ROOT = mkdtempSync(join(tmpdir(), "vibe-gw-"));
const OUTSIDE = mkdtempSync(join(tmpdir(), "vibe-gw-out-"));
process.env.VIBE_PROJECT_ROOTS = ROOT;
const git = (cwd: string, ...a: string[]) => execFileSync("git", a, { cwd, stdio: "pipe" }).toString();
const gitc = (cwd: string, ...a: string[]) => git(cwd, "-c", "user.name=t", "-c", "user.email=t@t", ...a);
let n = 0;

function repo(name = `r${++n}`) {
  const dir = join(ROOT, name);
  mkdirSync(dir);
  git(dir, "init", "-q", "-b", "main");
  writeFileSync(join(dir, "a.txt"), "one\n");
  writeFileSync(join(dir, "b.txt"), "bee\n");
  git(dir, "add", "-A");
  gitc(dir, "commit", "-q", "-m", "init");
  return dir;
}

async function setup() {
  const db = openDb(":memory:");
  const app = await buildApp(db);
  const { token } = (
    await app.inject({ method: "POST", url: "/pair", payload: { code: createPairingCode(db), device_name: "Pixel 8" } })
  ).json();
  const auth = { authorization: `Bearer ${token}` };
  const dir = repo();
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES ('p',?, 'p','unknown')").run(dir);
  const post = (url: string, payload: unknown, headers: Record<string, string> = auth) =>
    app.inject({ method: "POST", url, headers, payload: payload as any });
  return { db, app, auth, dir, post };
}

// ---- pure validators -----------------------------------------------------------

test("validBranchName: allowlist + the ref-format traps", () => {
  for (const ok of ["feat/x", "fix_1.2", "a", "A-b.c/d"]) assert.equal(validBranchName(ok), true, ok);
  const bad = ["", "-x", "--force", "a..b", "a@{b}", "x.lock", "a/", "a//b", "/a", ".a", " a", "a b", "a\nb", "a".repeat(65), "a~1", "a^", "a:b", "a?", "a*", "a[", "a\\b", 7, null];
  for (const b of bad) assert.equal(validBranchName(b), false, JSON.stringify(b));
});

test("validCommitMessage: 1-500 chars, no NUL, never starts with '-'", () => {
  for (const ok of ["fix: thing", "multi\nline", "has -dash inside", "x".repeat(500)]) assert.equal(validCommitMessage(ok), true);
  for (const bad of ["", "   ", "-m", "--amend", "  -F /etc/passwd", "a\0b", "x".repeat(501), 5, null]) {
    assert.equal(validCommitMessage(bad), false, JSON.stringify(bad));
  }
});

test("isSensitivePath: secrets by name, anywhere in the tree", () => {
  for (const s of [".env", ".env.local", "cfg/.env.prod", "k.pem", "a/b/server.key", "id_rsa", "x/id_ed25519.pub", ".netrc", "c.p12"]) {
    assert.equal(isSensitivePath(s), true, s);
  }
  for (const s of ["environment.ts", "README.md", "src/keyboard.dart", "monkey.txt"]) assert.equal(isSensitivePath(s), false, s);
});

test("checkStagePath: traversal, absolute-outside, option-like, .git, dirs, NUL, symlink escape", () => {
  const dir = repo();
  mkdirSync(join(dir, "sub"));
  symlinkSync(OUTSIDE, join(dir, "escape"));
  const why = (p: unknown) => {
    const r = checkStagePath(dir, p, false);
    return r.ok ? "OK" : r.why;
  };
  assert.equal(why("a.txt"), "OK");
  assert.equal(why(join(dir, "a.txt")), "OK");
  assert.equal(why("../x"), "outside the project");
  assert.equal(why(join(OUTSIDE, "x")), "outside the project");
  assert.equal(why("escape/secret"), "outside the project");
  assert.equal(why("--exec=evil"), "bad path");
  assert.equal(why("-f"), "bad path");
  assert.equal(why(".git/config"), "inside .git");
  assert.equal(why("sub"), "name files, not directories");
  assert.equal(why("."), "outside the project");
  assert.equal(why("a\0b"), "bad path");
  assert.equal(why(""), "bad path");
  assert.equal(why(42), "bad path");
  assert.match(why(".env"), /secret/);
  assert.equal(checkStagePath(dir, ".env", true).ok, true, "explicit opt-in");
});

// ---- stage ---------------------------------------------------------------------

test("stage with paths stages exactly those files", async () => {
  const { post, dir } = await setup();
  writeFileSync(join(dir, "a.txt"), "two\n");
  writeFileSync(join(dir, "b.txt"), "BEE\n");
  const r = await post("/projects/p/git/stage", { paths: ["a.txt"] });
  assert.equal(r.statusCode, 200);
  assert.deepEqual(r.json().staged, ["a.txt"]);
  assert.equal(git(dir, "diff", "--cached", "--name-only").trim(), "a.txt");
});

test("stage with no paths is `add -u`: tracked changes only, never untracked files", async () => {
  const { post, dir } = await setup();
  writeFileSync(join(dir, "a.txt"), "two\n");
  writeFileSync(join(dir, "new.txt"), "x\n");
  writeFileSync(join(dir, ".env"), "SECRET=1\n");
  const r = await post("/projects/p/git/stage", {});
  assert.deepEqual(r.json().staged, ["a.txt"]);
});

test("stage refuses hostile paths with 400 and stages nothing", async () => {
  const { post, dir } = await setup();
  writeFileSync(join(dir, "a.txt"), "two\n");
  symlinkSync(OUTSIDE, join(dir, "escape"));
  mkdirSync(join(dir, "sub"));
  const bodies: unknown[] = [
    { paths: ["../etc/passwd"] },
    { paths: ["--exec=evil"] },
    { paths: ["a.txt", "-A"] },
    { paths: [".git/config"] },
    { paths: ["sub"] },
    { paths: ["escape/x"] },
    { paths: [".env"] },
    { paths: [] },
    { paths: "a.txt" },
    { paths: [1] },
    { paths: Array.from({ length: 501 }, (_, i) => `f${i}`) },
  ];
  for (const b of bodies) {
    const r = await post("/projects/p/git/stage", b);
    assert.equal(r.statusCode, 400, JSON.stringify(b).slice(0, 60));
  }
  assert.equal(git(dir, "diff", "--cached", "--name-only").trim(), "", "nothing was staged by any refused request");
});

test("stage pathspecs are literal: a glob matches nothing and stages nothing", async () => {
  const { post, dir } = await setup();
  writeFileSync(join(dir, "a.txt"), "two\n");
  writeFileSync(join(dir, "b.txt"), "BEE\n");
  const r = await post("/projects/p/git/stage", { paths: ["*.txt"] });
  assert.equal(r.statusCode, 409);
  assert.equal(git(dir, "diff", "--cached", "--name-only").trim(), "");
});

test("a secret needs an explicit allowSensitive", async () => {
  const { post, dir } = await setup();
  writeFileSync(join(dir, ".env"), "SECRET=1\n");
  assert.equal((await post("/projects/p/git/stage", { paths: [".env"] })).statusCode, 400);
  const r = await post("/projects/p/git/stage", { paths: [".env"], allowSensitive: true });
  assert.deepEqual(r.json().staged, [".env"]);
});

test("session-scoped stage with no paths = the session's own edit set (secrets skipped)", async () => {
  const { post, dir, db } = await setup();
  db.prepare("INSERT INTO sessions (id, project_id, kind, status, created_at) VALUES ('s1','p','claude','live',?)").run(new Date().toISOString());
  writeFileSync(join(dir, "a.txt"), "two\n");
  writeFileSync(join(dir, "mine.txt"), "x\n");
  writeFileSync(join(dir, ".env"), "S=1\n");
  writeFileSync(join(dir, "b.txt"), "changed but not by the session\n");
  const tool = (file: string, i: number) =>
    db.prepare("INSERT INTO messages (id, session_id, role, tool_json, ts) VALUES (?,?,?,?,?)").run(
      `m${i}`, "s1", "tool", JSON.stringify({ id: `t${i}`, name: "Write", input: { file_path: file, content: "x" } }), `2026-01-01T00:00:0${i}Z`);
  tool(join(dir, "a.txt"), 1);
  tool(join(dir, "mine.txt"), 2);
  tool(join(dir, ".env"), 3);
  tool(join(OUTSIDE, "elsewhere.txt"), 4);
  const r = await post("/sessions/s1/git/stage", {});
  assert.equal(r.statusCode, 200);
  assert.deepEqual(r.json().staged.sort(), ["a.txt", "mine.txt"]);
  const none = await post("/sessions/nope/git/stage", {});
  assert.equal(none.statusCode, 404);
});

// ---- commit --------------------------------------------------------------------

async function staged(setupResult: Awaited<ReturnType<typeof setup>>, file = "a.txt") {
  writeFileSync(join(setupResult.dir, file), `edit ${Math.random()}\n`);
  git(setupResult.dir, "add", "--", file);
}

test("commit: literal message, device identity, sha/subject/count, audited", async () => {
  const s = await setup();
  await staged(s);
  const r = await s.post("/projects/p/git/commit", { message: "fix: handle --amend and -m flags literally\n\nbody line" });
  assert.equal(r.statusCode, 200);
  const j = r.json();
  assert.equal(j.sha, git(s.dir, "rev-parse", "HEAD").trim());
  assert.equal(j.subject, "fix: handle --amend and -m flags literally");
  assert.equal(j.filesChanged, 1);
  assert.equal(git(s.dir, "log", "-1", "--format=%B").trim(), "fix: handle --amend and -m flags literally\n\nbody line");
  assert.equal(git(s.dir, "log", "-1", "--format=%an").trim(), "Pixel 8");
  assert.match(git(s.dir, "log", "-1", "--format=%ae").trim(), /^[0-9a-f-]{36}@vibe\.local$/);
  assert.equal(git(s.dir, "rev-list", "--count", "HEAD").trim(), "2");
  assert.ok(s.db.prepare("SELECT 1 FROM events WHERE kind='git.commit'").get());
});

test("commit refuses option-shaped, NUL, empty and oversized messages without committing", async () => {
  const s = await setup();
  await staged(s);
  for (const message of ["--amend", "-F /etc/passwd", " -m x", "", "   ", "a\0b", "x".repeat(501), 7, undefined]) {
    assert.equal((await s.post("/projects/p/git/commit", { message })).statusCode, 400, JSON.stringify(message)?.slice(0, 30));
  }
  assert.equal(git(s.dir, "rev-list", "--count", "HEAD").trim(), "1", "no commit was made");
});

test("commit with nothing staged is 409", async () => {
  const { post } = await setup();
  assert.equal((await post("/projects/p/git/commit", { message: "empty" })).statusCode, 409);
});

test("commit works even when the repo demands gpg signing", async () => {
  const s = await setup();
  git(s.dir, "config", "commit.gpgsign", "true");
  git(s.dir, "config", "gpg.program", "/nonexistent/gpg");
  await staged(s);
  assert.equal((await s.post("/projects/p/git/commit", { message: "signed? no" })).statusCode, 200);
});

test("planted hooks and config in .git never execute (stage, commit, branch)", async () => {
  const s = await setup();
  const marker = (name: string) => join(s.dir, name);
  const plant = (file: string, body: string) => {
    mkdirSync(join(s.dir, ".git", "hooks"), { recursive: true });
    writeFileSync(join(s.dir, ".git", "hooks", file), `#!/bin/sh\n${body}\n`, { mode: 0o755 });
  };
  plant("pre-commit", `touch "${marker("PWNED_pre")}"`);
  plant("commit-msg", `touch "${marker("PWNED_msg")}"`);
  plant("post-commit", `touch "${marker("PWNED_post")}"`);
  plant("post-checkout", `touch "${marker("PWNED_co")}"`);
  const fsm = join(s.dir, "evil-fsm.sh");
  writeFileSync(fsm, `#!/bin/sh\ntouch "${marker("PWNED_fsm")}"\n`, { mode: 0o755 });
  git(s.dir, "config", "core.fsmonitor", fsm);
  git(s.dir, "config", "core.hooksPath", join(s.dir, ".git", "hooks")); // even an explicit repo hooksPath

  // control: plain git DOES run them (so the assertions below prove something)
  writeFileSync(join(s.dir, "ctl.txt"), "x\n");
  execFileSync("git", ["add", "ctl.txt"], { cwd: s.dir, stdio: "pipe" });
  execFileSync("git", ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "ctl"], { cwd: s.dir, stdio: "pipe" });
  for (const m of ["PWNED_pre", "PWNED_msg", "PWNED_post", "PWNED_fsm"]) assert.ok(existsSync(marker(m)), `control: ${m} should fire under plain git`);
  for (const m of ["PWNED_pre", "PWNED_msg", "PWNED_post", "PWNED_fsm"]) execFileSync("rm", [marker(m)]);

  writeFileSync(join(s.dir, "a.txt"), "changed\n");
  assert.equal((await s.post("/projects/p/git/stage", { paths: ["a.txt"] })).statusCode, 200);
  assert.equal((await s.post("/projects/p/git/commit", { message: "via daemon" })).statusCode, 200);
  assert.equal((await s.post("/projects/p/git/branch", { name: "feat/x" })).statusCode, 200);
  for (const m of ["PWNED_pre", "PWNED_msg", "PWNED_post", "PWNED_fsm", "PWNED_co"]) {
    assert.equal(existsSync(marker(m)), false, `${m} must not fire through the daemon`);
  }
});

test("concurrent commits on one checkout serialize: one wins, the other sees nothing staged", async () => {
  const s = await setup();
  await staged(s);
  const [a, b] = await Promise.all([
    s.post("/projects/p/git/commit", { message: "one" }),
    s.post("/projects/p/git/commit", { message: "two" }),
  ]);
  assert.deepEqual([a.statusCode, b.statusCode].sort(), [200, 409]);
  assert.equal(git(s.dir, "rev-list", "--count", "HEAD").trim(), "2");
});

// ---- branch --------------------------------------------------------------------

test("branch: creates and switches; bad names are 400; duplicates and dirty trees are 409", async () => {
  const s = await setup();
  const r = await s.post("/projects/p/git/branch", { name: "feat/new-thing" });
  assert.equal(r.statusCode, 200);
  assert.equal(git(s.dir, "rev-parse", "--abbrev-ref", "HEAD").trim(), "feat/new-thing");
  for (const name of ["-x", "a..b", "a@{b}", "x.lock", "a/", "", "has space", 5]) {
    assert.equal((await s.post("/projects/p/git/branch", { name })).statusCode, 400, JSON.stringify(name));
  }
  const dup = await s.post("/projects/p/git/branch", { name: "main" });
  assert.equal(dup.statusCode, 409);
  assert.doesNotMatch(dup.body, /fatal|already exists|\/tmp/i, "git's own stderr/paths are not echoed");
  writeFileSync(join(s.dir, "a.txt"), "dirty\n");
  assert.equal((await s.post("/projects/p/git/branch", { name: "other" })).statusCode, 409);
  assert.equal(git(s.dir, "rev-parse", "--abbrev-ref", "HEAD").trim(), "feat/new-thing", "a refused request did not switch");
  git(s.dir, "checkout", "--", "a.txt");
  writeFileSync(join(s.dir, "scratch.log"), "untracked build output\n");
  assert.equal((await s.post("/projects/p/git/branch", { name: "with-untracked" })).statusCode, 200, "untracked files don't block");
});

// ---- scope / auth ----------------------------------------------------------------

test("unknown project/session is 404; no token is 401; push is still 404", async () => {
  const { post } = await setup();
  assert.equal((await post("/projects/zzz/git/commit", { message: "x" })).statusCode, 404);
  assert.equal((await post("/sessions/zzz/git/branch", { name: "x" })).statusCode, 404);
  assert.equal((await post("/projects/p/git/commit", { message: "x" }, {})).statusCode, 401);
  assert.equal((await post("/projects/p/git/push", {})).statusCode, 404);
});

test("a project outside VIBE_PROJECT_ROOTS is refused (403)", async () => {
  const { db, post } = await setup();
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES ('out',?, 'out','unknown')").run(OUTSIDE);
  assert.equal((await post("/projects/out/git/stage", {})).statusCode, 403);
});

// ---- worktree sessions ---------------------------------------------------------------

test("a worktree session commits to its own branch; the main checkout is untouched", async () => {
  const { post, db, dir, app, auth } = await setup();
  const created = (await post("/sessions", { project_id: "p", kind: "claude", worktree: true })).json();
  const wt = (db.prepare("SELECT worktree_path FROM sessions WHERE id=?").get(created.id) as any).worktree_path as string;
  writeFileSync(join(wt, "a.txt"), "from the worktree\n");

  const st = (await app.inject({ method: "GET", url: `/sessions/${created.id}/git-status`, headers: auth })).json();
  assert.equal(st.branch, created.worktree_branch);
  assert.deepEqual(st.files.map((f: any) => f.path), ["a.txt"]);

  assert.equal((await post(`/sessions/${created.id}/git/stage`, { paths: ["a.txt"] })).statusCode, 200);
  const c = await post(`/sessions/${created.id}/git/commit`, { message: "work in isolation" });
  assert.equal(c.statusCode, 200);
  assert.equal(git(dir, "rev-parse", "HEAD").trim(), git(dir, "rev-parse", "main").trim());
  assert.notEqual(git(dir, "rev-parse", created.worktree_branch).trim(), git(dir, "rev-parse", "main").trim());
  assert.equal(git(dir, "show", "main:a.txt"), "one\n", "main still has the old content");

  // the committed work now makes DELETE keep the worktree
  const del = await app.inject({ method: "DELETE", url: `/sessions/${created.id}`, headers: auth });
  assert.equal(del.statusCode, 200);
  assert.equal(del.json().reason, "commits");
});

test("session-scoped git-status of a plain session reads the project checkout", async () => {
  const { post, app, auth, dir } = await setup();
  const created = (await post("/sessions", { project_id: "p", kind: "claude" })).json();
  writeFileSync(join(dir, "a.txt"), "dirty\n");
  const st = (await app.inject({ method: "GET", url: `/sessions/${created.id}/git-status`, headers: auth })).json();
  assert.deepEqual(st.files.map((f: any) => f.path), ["a.txt"]);
  assert.equal((await app.inject({ method: "GET", url: "/sessions/zzz/git-status", headers: auth })).statusCode, 404);
});
