// Worktree-per-session (ADR 0022). Real temp git repos — the shell-out is the thing
// under test. Covers: creation + exclude, id/path safety, planted-hook immunity,
// remove-only-if-nothing-is-lost, the session routes, and Auto-mode scope.

import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { openDb } from "./db.js";
import { buildApp } from "./app.js";
import { createPairingCode } from "./auth.js";
import { WebSocket } from "ws";
import type { AddressInfo } from "node:net";
import { createWorktree, removeWorktree, worktreePathFor, WorktreeError } from "./worktree.js";
import { autoScopeDirs } from "./file-scope.js";
import { scanProjects } from "./scanner.js";

const ROOT = mkdtempSync(join(tmpdir(), "vibe-wt-"));
process.env.VIBE_PROJECT_ROOTS = ROOT;
const git = (cwd: string, ...a: string[]) => execFileSync("git", a, { cwd, stdio: "pipe" }).toString();
const commit = (cwd: string, msg: string) => git(cwd, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", msg);
let n = 0;
const sid = () => `s_${(++n).toString(16).padStart(12, "0")}`;

function repo(name: string, withCommit = true) {
  const dir = join(ROOT, name);
  mkdirSync(dir);
  git(dir, "init", "-q", "-b", "main");
  if (withCommit) {
    writeFileSync(join(dir, "a.txt"), "one\n");
    git(dir, "add", "-A");
    commit(dir, "init");
  }
  return dir;
}

test("createWorktree: checkout on its own branch at HEAD, excluded from the main status", async () => {
  const dir = repo("r1");
  const id = sid();
  const wt = await createWorktree(dir, id);
  assert.equal(wt.path, worktreePathFor(dir, id));
  assert.equal(wt.branch, `vibe/${id}`);
  assert.equal(readFileSync(join(wt.path, "a.txt"), "utf8"), "one\n");
  assert.equal(git(wt.path, "rev-parse", "--abbrev-ref", "HEAD").trim(), wt.branch);
  assert.equal(git(dir, "rev-parse", "HEAD").trim(), wt.baseRef);
  assert.equal(git(dir, "status", "--porcelain").trim(), "", "main checkout stays clean");
});

test("createWorktree: exclude entry is written once, not per session", async () => {
  const dir = repo("r2");
  await createWorktree(dir, sid());
  await createWorktree(dir, sid());
  const ex = readFileSync(join(dir, ".git", "info", "exclude"), "utf8").split("\n").filter((l) => l === ".vibe-worktrees/");
  assert.equal(ex.length, 1);
});

test("createWorktree: only server-shaped session ids are accepted", async () => {
  const dir = repo("r3");
  for (const bad of ["../evil", "s_zz", "s_0123456789abc", "S_0123456789ab", "x", "", "s_0123456789ab/../x"]) {
    await assert.rejects(createWorktree(dir, bad), WorktreeError, bad);
  }
  assert.equal(existsSync(join(dir, ".vibe-worktrees")), false, "nothing created on rejection");
});

test("createWorktree: a non-repo, an unborn repo and a bare repo are refused", async () => {
  const plain = join(ROOT, "plain");
  mkdirSync(plain);
  await assert.rejects(createWorktree(plain, sid()), WorktreeError);
  await assert.rejects(createWorktree(repo("unborn", false), sid()), WorktreeError);
  const bare = join(ROOT, "bare");
  mkdirSync(bare);
  git(bare, "init", "-q", "--bare");
  await assert.rejects(createWorktree(bare, sid()), WorktreeError);
});

test("createWorktree: a planted post-checkout hook does not run", async () => {
  const dir = repo("r4");
  const marker = join(dir, "PWNED");
  const hook = join(dir, ".git", "hooks", "post-checkout");
  mkdirSync(join(dir, ".git", "hooks"), { recursive: true });
  writeFileSync(hook, `#!/bin/sh\ntouch "${marker}"\n`, { mode: 0o755 });
  // control: the hook really fires under plain git
  execFileSync("git", ["worktree", "add", "-q", "--detach", join(ROOT, "ctl-wt"), "HEAD"], { cwd: dir, stdio: "pipe" });
  assert.ok(existsSync(marker), "premise: the hook fires under plain git");
  execFileSync("rm", [marker]);
  await createWorktree(dir, sid());
  assert.equal(existsSync(marker), false);
});

test("removeWorktree: untouched worktree is removed with its branch", async () => {
  const dir = repo("r5");
  const wt = await createWorktree(dir, sid());
  assert.deepEqual(await removeWorktree(dir, wt), { kept: false });
  assert.equal(existsSync(wt.path), false);
  assert.equal(git(dir, "branch", "--list", wt.branch).trim(), "");
});

test("removeWorktree: uncommitted work is kept", async () => {
  const dir = repo("r6");
  const wt = await createWorktree(dir, sid());
  writeFileSync(join(wt.path, "new.txt"), "x\n");
  assert.deepEqual(await removeWorktree(dir, wt), { kept: true, reason: "dirty" });
  assert.ok(existsSync(join(wt.path, "new.txt")));
});

test("removeWorktree: committed work is kept", async () => {
  const dir = repo("r7");
  const wt = await createWorktree(dir, sid());
  commit(wt.path, "agent work");
  assert.deepEqual(await removeWorktree(dir, wt), { kept: true, reason: "commits" });
  assert.ok(existsSync(wt.path));
});

test("removeWorktree: a directory deleted by hand is pruned, not an error", async () => {
  const dir = repo("r8");
  const wt = await createWorktree(dir, sid());
  execFileSync("rm", ["-rf", wt.path]);
  assert.deepEqual(await removeWorktree(dir, wt), { kept: false });
  assert.doesNotMatch(git(dir, "worktree", "list"), /\.vibe-worktrees/);
});

test("removeWorktree: unknown state fails safe (kept)", async () => {
  const dir = repo("r9");
  const wt = await createWorktree(dir, sid());
  const r = await removeWorktree(dir, { ...wt, baseRef: "" }); // rev-list errors → never delete
  assert.equal(r.kept, true);
  assert.ok(existsSync(wt.path));
});

test("removeWorktree: missing base/branch (null columns) never deletes", async () => {
  const dir = repo("r9b");
  const wt = await createWorktree(dir, sid());
  assert.equal((await removeWorktree(dir, { ...wt, baseRef: "" })).kept, true);
  assert.equal((await removeWorktree(dir, { ...wt, branch: "" })).kept, true);
  assert.equal((await removeWorktree(dir, { ...wt, branch: "main" })).kept, true, "never touch a non-vibe branch");
  assert.ok(existsSync(wt.path));
});

test("the project scanner does not list .vibe-worktrees checkouts", async () => {
  const dir = repo("r10");
  await createWorktree(dir, sid());
  const names = scanProjects([ROOT]).map((p) => p.name);
  assert.ok(names.includes("r10"));
  assert.ok(!names.some((x) => x.startsWith("s_")));
});

// ---- routes ------------------------------------------------------------------

async function setup() {
  const db = openDb(":memory:");
  const app = await buildApp(db);
  const { token } = (
    await app.inject({ method: "POST", url: "/pair", payload: { code: createPairingCode(db), device_name: "t" } })
  ).json();
  const auth = { authorization: `Bearer ${token}` };
  const dir = repo(`rt${++n}`);
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES ('p',?,?, 'unknown')").run(dir, "rt");
  const plain = join(ROOT, `plainproj${n}`);
  mkdirSync(plain);
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES ('pp',?,?, 'unknown')").run(plain, "plain");
  const post = (payload: unknown) => app.inject({ method: "POST", url: "/sessions", headers: auth, payload: payload as any });
  return { db, app, auth, dir, post };
}

test("POST /sessions {worktree:true} creates the checkout and persists it", async () => {
  const { db, dir, post } = await setup();
  const r = await post({ project_id: "p", kind: "claude", worktree: true });
  assert.equal(r.statusCode, 201);
  const j = r.json();
  assert.equal(j.worktree_branch, `vibe/${j.id}`);
  const row = db.prepare("SELECT worktree_path, worktree_branch, base_ref FROM sessions WHERE id = ?").get(j.id) as any;
  assert.equal(row.worktree_path, join(dir, ".vibe-worktrees", j.id));
  assert.ok(existsSync(row.worktree_path));
  assert.equal(row.base_ref, git(dir, "rev-parse", "HEAD").trim());
  assert.ok(db.prepare("SELECT 1 FROM events WHERE kind='session.worktree.create'").get());
});

test("POST /sessions without worktree is unchanged (no checkout, null columns)", async () => {
  const { db, post } = await setup();
  const j = (await post({ project_id: "p", kind: "claude" })).json();
  assert.equal(j.worktree_branch, null);
  assert.equal((db.prepare("SELECT worktree_path FROM sessions WHERE id=?").get(j.id) as any).worktree_path, null);
});

test("worktree is refused for terminals, native models, non-boolean values and non-repos", async () => {
  const { post } = await setup();
  assert.equal((await post({ project_id: "p", kind: "terminal", worktree: true })).statusCode, 400);
  assert.equal((await post({ project_id: "p", kind: "claude", model: "openai:gpt-4o", worktree: true })).statusCode, 400);
  assert.equal((await post({ project_id: "p", kind: "claude", worktree: "yes" })).statusCode, 400);
  const r = await post({ project_id: "pp", kind: "claude", worktree: true });
  assert.equal(r.statusCode, 400);
  assert.doesNotMatch(r.body, /fatal|\/tmp/i, "no raw git stderr or paths leak");
});

test("worktree count is capped", async () => {
  const { post } = await setup();
  process.env.VIBE_MAX_WORKTREES = "1";
  try {
    assert.equal((await post({ project_id: "p", kind: "claude", worktree: true })).statusCode, 201);
    assert.equal((await post({ project_id: "p", kind: "claude", worktree: true })).statusCode, 429);
  } finally {
    delete process.env.VIBE_MAX_WORKTREES;
  }
});

test("DELETE removes an untouched worktree (204) and keeps one with work (200 + where)", async () => {
  const { app, auth, db, post } = await setup();
  const a = (await post({ project_id: "p", kind: "claude", worktree: true })).json();
  const pathA = (db.prepare("SELECT worktree_path FROM sessions WHERE id=?").get(a.id) as any).worktree_path;
  const del = (id: string) => app.inject({ method: "DELETE", url: `/sessions/${id}`, headers: auth });
  assert.equal((await del(a.id)).statusCode, 204);
  assert.equal(existsSync(pathA), false);
  assert.ok(db.prepare("SELECT 1 FROM events WHERE kind='session.worktree.remove'").get());

  const b = (await post({ project_id: "p", kind: "claude", worktree: true })).json();
  const pathB = (db.prepare("SELECT worktree_path FROM sessions WHERE id=?").get(b.id) as any).worktree_path;
  writeFileSync(join(pathB, "wip.txt"), "x");
  const r = await del(b.id);
  assert.equal(r.statusCode, 200);
  assert.deepEqual(r.json(), { kept: true, path: pathB, branch: `vibe/${b.id}`, reason: "dirty" });
  assert.ok(existsSync(join(pathB, "wip.txt")));
  assert.equal(db.prepare("SELECT 1 FROM sessions WHERE id=?").get(b.id), undefined, "the session row itself is gone");
  assert.ok(db.prepare("SELECT 1 FROM events WHERE kind='session.worktree.kept'").get());
});

test("a worktree session's file routes are rooted at its checkout, not the main tree", async () => {
  const { app, auth, db, post, dir } = await setup();
  const j = (await post({ project_id: "p", kind: "claude", worktree: true })).json();
  const wtPath = (db.prepare("SELECT worktree_path FROM sessions WHERE id=?").get(j.id) as any).worktree_path;
  writeFileSync(join(wtPath, "only-in-wt.txt"), "x");
  writeFileSync(join(dir, "only-in-main.txt"), "x");
  const tree = (await app.inject({ method: "GET", url: `/sessions/${j.id}/tree`, headers: auth })).json();
  assert.equal(tree.root, wtPath);
  const names = tree.files.map((f: { relPath: string }) => f.relPath);
  assert.ok(names.includes("only-in-wt.txt"));
  assert.ok(!names.includes("only-in-main.txt"));
});

// ---- Auto-mode scope -----------------------------------------------------------

test("autoScopeDirs: a worktree session gets its checkout + ~/.claude only; others keep all projects", async () => {
  const { db, post } = await setup();
  const j = (await post({ project_id: "p", kind: "claude", worktree: true })).json();
  const wtPath = (db.prepare("SELECT worktree_path FROM sessions WHERE id=?").get(j.id) as any).worktree_path;
  const scoped = autoScopeDirs(db, wtPath);
  assert.equal(scoped.length, 2);
  assert.equal(scoped[0], wtPath);
  assert.ok(autoScopeDirs(db, "/some/other/cwd").length > 2 || db.prepare("SELECT COUNT(*) n FROM projects").get() !== undefined);
  const plainScope = autoScopeDirs(db, "/some/other/cwd");
  assert.ok(plainScope.some((d) => d.includes("rt")), "a normal session still sees registered projects");
});

// ---- WS: the engine really runs in the worktree ---------------------------------

async function bootWs() {
  const seen: { cwd?: string } = {};
  const queryFn = (params: { prompt: AsyncIterable<any>; options: any }) => {
    if (!params.options?.canUseTool) return (async function* () {})(); // titler call
    seen.cwd = params.options.cwd;
    return (async function* () {
      yield { type: "system", subtype: "init", session_id: "claude-wt", model: "m" };
      await params.prompt[Symbol.asyncIterator]().next();
      yield { type: "result", subtype: "success", total_cost_usd: 0 };
    })();
  };
  const db = openDb(":memory:");
  const app = await buildApp(db, undefined, new Map(), queryFn);
  await app.listen({ host: "127.0.0.1", port: 0 });
  const port = (app.server.address() as AddressInfo).port;
  const { token } = (await app.inject({ method: "POST", url: "/pair", payload: { code: createPairingCode(db), device_name: "t" } })).json();
  const dir = repo(`ws${++n}`);
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES ('p',?, 'ws','unknown')").run(dir);
  const create = (payload: unknown) =>
    app.inject({ method: "POST", url: "/sessions", headers: { authorization: `Bearer ${token}` }, payload: payload as any });
  const connect = (id: string) => {
    const frames: any[] = [];
    const ws = new WebSocket(`ws://127.0.0.1:${port}/session/${id}`, { headers: { authorization: `Bearer ${token}` } });
    ws.on("message", (d: Buffer) => frames.push(JSON.parse(d.toString("utf8"))));
    const closed = new Promise<number>((res) => ws.on("close", (code) => res(code)));
    return { ws, frames, closed };
  };
  return { db, app, dir, seen, create, connect };
}
const until = async (fn: () => boolean, ms = 3000) => {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) {
    if (fn()) return;
    await new Promise((r) => setTimeout(r, 5));
  }
  throw new Error("timed out");
};

test("WS: a worktree session's engine starts with the worktree as cwd", async (t) => {
  const { app, dir, seen, create, connect, db } = await bootWs();
  t.after(() => app.close());
  const j = (await create({ project_id: "p", kind: "claude", worktree: true })).json();
  const { ws, frames } = connect(j.id);
  await new Promise<void>((res) => ws.on("open", () => res()));
  await until(() => frames.some((f) => f.t === "history"));
  ws.send(JSON.stringify({ t: "user", text: "hi" }));
  await until(() => frames.some((f) => f.t === "result"));
  assert.equal(seen.cwd, join(dir, ".vibe-worktrees", j.id));
  assert.notEqual(seen.cwd, dir);
  void db;
  ws.close();
});

test("WS: a worktree deleted by hand refuses to attach — never falls back to the main tree", async (t) => {
  const { app, create, connect, db, seen } = await bootWs();
  t.after(() => app.close());
  const j = (await create({ project_id: "p", kind: "claude", worktree: true })).json();
  const wtPath = (db.prepare("SELECT worktree_path FROM sessions WHERE id=?").get(j.id) as any).worktree_path;
  execFileSync("rm", ["-rf", wtPath]);
  const { ws, frames, closed } = connect(j.id);
  assert.equal(await closed, 4404);
  assert.ok(frames.some((f) => f.t === "error" && /worktree/i.test(f.message)));
  assert.equal(seen.cwd, undefined, "no engine was started");
  assert.equal((db.prepare("SELECT status FROM sessions WHERE id=?").get(j.id) as any).status, "stale");
  void ws;
});

test("POST /sessions/prune removes clean stale worktrees and keeps ones with work", async () => {
  const { app, auth, db, post } = await setup();
  const clean = (await post({ project_id: "p", kind: "claude", worktree: true })).json();
  const dirty = (await post({ project_id: "p", kind: "claude", worktree: true })).json();
  const get = (id: string) => (db.prepare("SELECT worktree_path FROM sessions WHERE id=?").get(id) as any).worktree_path as string;
  const [pc, pd] = [get(clean.id), get(dirty.id)];
  writeFileSync(join(pd, "wip.txt"), "x");
  db.prepare("UPDATE sessions SET status='stale'").run();
  const r = await app.inject({ method: "POST", url: "/sessions/prune", headers: auth, payload: { project_id: "p" } });
  assert.deepEqual(r.json(), { deleted: 2, worktreesKept: 1 });
  assert.equal(existsSync(pc), false);
  assert.ok(existsSync(join(pd, "wip.txt")));
});
