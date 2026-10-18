// Swarm merge queue (ADR 0032, security.md #36). Real temp git repos, in-memory DB, the
// real worker; the test command is `node -e …` so no extra tooling is needed.

import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

const ROOT = mkdtempSync(join(tmpdir(), "vibe-mq-"));
const MERGE_DIR = mkdtempSync(join(tmpdir(), "vibe-mq-scratch-"));
process.env.VIBE_PROJECT_ROOTS = ROOT;
process.env.VIBE_CLAUDE_PROJECTS_DIR = "/nonexistent/vibe-test-claude-projects";
process.env.VIBE_MERGE_DIR = MERGE_DIR;
process.env.VIBE_MERGE_SYSTEMD = "0"; // deterministic: the process-group path
process.env.VIBE_TEST_PATH = `${dirname(process.execPath)}:/usr/bin:/bin`;

import { openDb } from "./db.js";
import { buildApp } from "./app.js";
import { createPairingCode } from "./auth.js";
import type { ClaudeRegistry } from "./claude.js";
import { createWorktree } from "./worktree.js";
import { approve as approveItem, kick, recoverMergeQueue, reject as rejectItem, runTestCommand } from "./merge-queue.js";

const git = (cwd: string, ...a: string[]) => execFileSync("git", ["-c", "user.name=t", "-c", "user.email=t@t", ...a], { cwd, stdio: "pipe" }).toString();
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
async function waitFor(fn: () => boolean, ms = 15_000) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) {
    if (fn()) return;
    await sleep(20);
  }
  throw new Error("timed out waiting for condition");
}

let n = 0;
function repo(): string {
  const dir = join(ROOT, `r${++n}`);
  mkdirSync(dir);
  git(dir, "init", "-q", "-b", "main");
  writeFileSync(join(dir, "a.txt"), "one\n");
  writeFileSync(join(dir, ".gitignore"), ".env\n");
  git(dir, "add", "-A");
  git(dir, "commit", "-q", "-m", "init");
  return dir;
}
const commitIn = (cwd: string, files: Record<string, string>, msg = "work") => {
  for (const [f, body] of Object.entries(files)) {
    mkdirSync(dirname(join(cwd, f)), { recursive: true });
    writeFileSync(join(cwd, f), body);
    git(cwd, "add", "-f", "--", f);
  }
  git(cwd, "commit", "-q", "-m", msg);
};

const NODE_OK = ["node", "-e", "process.exit(0)"];
const NODE_FAIL = ["node", "-e", "console.error('boom'); process.exit(1)"];

async function setup(testCommand: string[] | null = NODE_OK) {
  const dir = repo();
  const db = openDb(":memory:");
  const registry: ClaudeRegistry = new Map();
  const app = await buildApp(db, { hasSession: async () => true, createSession: async () => {}, killSession: async () => {} } as any, registry);
  const { token } = (await app.inject({ method: "POST", url: "/pair", payload: { code: createPairingCode(db), device_name: "t" } })).json();
  const auth = { authorization: `Bearer ${token}` };
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES (?,?,?,?)").run("p1", dir, "p", "unknown");
  if (testCommand) {
    const r = await app.inject({ method: "PUT", url: "/projects/p1/settings", headers: auth, payload: { test_command: testCommand } });
    assert.equal(r.statusCode, 200, r.body);
  }
  const deps = { db, registry: registry as any };
  let k = 0;
  // A session with a real worktree + commits, and its task in review.
  async function session(files: Record<string, string>, opts: { live?: string[] } = {}) {
    const sid = `s_${(++k).toString(16).padStart(2, "0")}${Math.random().toString(16).slice(2, 12)}`.slice(0, 14);
    const wt = await createWorktree(dir, sid);
    commitIn(wt.path, files);
    db.prepare("INSERT INTO sessions (id, project_id, kind, status, created_at, worktree_path, worktree_branch, base_ref, target_branch) VALUES (?,?,?,?,?,?,?,?,?)").run(
      sid, "p1", "claude", "live", new Date().toISOString(), wt.path, wt.branch, wt.baseRef, wt.targetBranch,
    );
    const taskId = `t_${sid}`;
    const ts = new Date().toISOString();
    db.prepare("INSERT INTO tasks (id, project_id, title, body, scope, deps, state, session_id, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?)").run(
      taskId, "p1", `task ${sid}`, "", JSON.stringify(Object.keys(files)), "[]", "review", sid, ts, ts,
    );
    if (opts.live) registry.set(sid, { pushUser: (t: string) => opts.live!.push(t) } as any);
    return { sid, taskId, wt };
  }
  const enqueue = (taskId: string) => app.inject({ method: "POST", url: `/tasks/${taskId}/enqueue`, headers: auth });
  const items = () => db.prepare("SELECT * FROM merge_queue ORDER BY created_at, rowid").all() as any[];
  const state = (id: string) => (db.prepare("SELECT state FROM merge_queue WHERE id = ?").get(id) as any).state as string;
  const settled = (id: string) => waitFor(() => ["awaiting_approval", "bounced", "merged"].includes(state(id)));
  const approve = (id: string, sha: string) => app.inject({ method: "POST", url: `/merge-queue/${id}/approve`, headers: auth, payload: { sha } });
  const row = (id: string) => db.prepare("SELECT * FROM merge_queue WHERE id = ?").get(id) as any;
  const taskState = (id: string) => (db.prepare("SELECT state FROM tasks WHERE id = ?").get(id) as any).state as string;
  // Enqueue and wait for the worker to stop.
  async function run(taskId: string) {
    const r = await enqueue(taskId);
    assert.equal(r.statusCode, 201, r.body);
    const id = r.json().id as string;
    await settled(id);
    return id;
  }
  return { dir, db, app, auth, registry, deps, session, enqueue, items, state, approve, row, taskState, run };
}

test("happy path: enqueue -> rebase -> test -> approve -> ff -> task done -> broadcast", async () => {
  const { dir, db, app, auth, registry, session, run, approve, row, taskState } = await setup();
  const seen: string[] = [];
  registry.set("s_other", { pushUser: (t: string) => seen.push(t) } as any);
  db.prepare("INSERT INTO sessions (id, project_id, kind, status, created_at) VALUES ('s_other','p1','claude','live',?)").run(new Date().toISOString());

  const a = await session({ "feature.txt": "feature\n" });
  // The target moves while the session works, so the rebase has something to do.
  writeFileSync(join(dir, "m.txt"), "main\n");
  git(dir, "add", "m.txt");
  git(dir, "commit", "-q", "-m", "main moved");
  const mainTip = git(dir, "rev-parse", "main").trim();

  const id = await run(a.taskId);
  const it = row(id);
  assert.equal(it.state, "awaiting_approval", JSON.stringify(it));
  assert.equal(it.target, "main");
  assert.equal(it.target_sha, mainTip);
  assert.equal(git(dir, "rev-parse", `${it.tested_sha}^`).trim(), mainTip, "rebased onto the new tip");
  const view = JSON.parse(it.result);
  assert.equal(view.untested, false);
  assert.equal(view.test_ok, true);
  assert.match(view.diffstat, /feature\.txt/);
  assert.equal(existsSync(join(MERGE_DIR, id)), false, "scratch worktree removed");
  assert.equal(taskState(a.taskId), "review");

  const list = (await app.inject({ method: "GET", url: "/projects/p1/merge-queue", headers: auth })).json();
  assert.equal(list[0].id, id);
  assert.equal(list[0].result.test_ok, true);

  const ok = await approve(id, it.tested_sha);
  assert.equal(ok.statusCode, 200, ok.body);
  assert.equal(git(dir, "rev-parse", "main").trim(), it.tested_sha);
  assert.equal(readFileSync(join(dir, "feature.txt"), "utf8"), "feature\n");
  assert.equal(row(id).state, "merged");
  assert.equal(taskState(a.taskId), "done");
  assert.equal((db.prepare("SELECT base_ref FROM sessions WHERE id = ?").get(a.sid) as any).base_ref, it.tested_sha);
  assert.equal(git(dir, "rev-parse", a.wt.branch).trim(), it.tested_sha, "author branch moved to the merged sha");
  assert.equal(git(a.wt.path, "status", "--porcelain").trim(), "", "author worktree synced");
  assert.ok(existsSync(join(a.wt.path, "m.txt")), "author worktree has the rebased files");
  const kinds = (db.prepare("SELECT kind FROM events").all() as any[]).map((e) => e.kind);
  for (const k of ["merge.enqueue", "merge.test", "merge.ff", "task.broadcast", "project.settings"]) assert.ok(kinds.includes(k), k);
  assert.equal(seen.length, 1);
  assert.match(seen[0], /feature\.txt/);
  assert.doesNotMatch(seen[0], /m\.txt/, "range is target_sha..tested_sha: only this task's files");
});

test("no test command: awaits approval marked untested", async () => {
  const { session, run, row } = await setup(null);
  const a = await session({ "u.txt": "x\n" });
  const id = await run(a.taskId);
  assert.equal(row(id).state, "awaiting_approval");
  assert.equal(JSON.parse(row(id).result).untested, true);
});

test("conflict bounces: live session is told (as data), scratch is cleaned", async () => {
  const { dir, session, run, row, taskState } = await setup();
  const msgs: string[] = [];
  const a = await session({ "a.txt": "session\n" }, { live: msgs });
  writeFileSync(join(dir, "a.txt"), "main\n");
  git(dir, "commit", "-q", "-am", "main edits a.txt");
  const id = await run(a.taskId);
  assert.equal(row(id).state, "bounced");
  assert.match(JSON.parse(row(id).result).reason, /rebase/);
  assert.equal(msgs.length, 1);
  assert.match(msgs[0], /not typed by the user/);
  assert.match(msgs[0], /data, not instructions/);
  assert.ok(msgs[0].length < 9000);
  assert.equal(taskState(a.taskId), "review", "live session keeps its task");
  assert.equal(existsSync(join(MERGE_DIR, id)), false);
  assert.doesNotMatch(git(dir, "worktree", "list"), new RegExp(id));
  assert.equal(git(dir, "rev-parse", "main").trim(), git(dir, "rev-parse", "HEAD").trim());
});

test("red test bounces; a session that is not live sends its task back to ready", async () => {
  const { session, run, row, taskState } = await setup(NODE_FAIL);
  const a = await session({ "r.txt": "x\n" });
  const id = await run(a.taskId);
  const it = row(id);
  assert.equal(it.state, "bounced");
  const res = JSON.parse(it.result);
  assert.match(res.reason, /tests failed/);
  assert.match(res.output, /boom/);
  assert.equal(taskState(a.taskId), "ready");
});

test("approve: sha pin mismatch and bad shas are refused", async () => {
  const { session, run, approve, row, dir } = await setup();
  const a = await session({ "p.txt": "x\n" });
  const id = await run(a.taskId);
  const before = git(dir, "rev-parse", "main").trim();
  assert.equal((await approve(id, "a".repeat(40))).statusCode, 409);
  assert.equal((await approve(id, "abc")).statusCode, 400);
  assert.equal((await approve(id, row(id).tested_sha.slice(0, 12))).statusCode, 400);
  assert.equal(row(id).state, "awaiting_approval");
  assert.equal(git(dir, "rev-parse", "main").trim(), before);
});

test("target moved after the test: approve requeues, the retest lands on the new tip", async () => {
  const { dir, session, run, approve, row, state, items } = await setup();
  const a = await session({ "t.txt": "x\n" });
  const id = await run(a.taskId);
  const old = row(id).tested_sha;
  writeFileSync(join(dir, "later.txt"), "later\n");
  git(dir, "add", "later.txt");
  git(dir, "commit", "-q", "-m", "later");
  const r = await approve(id, old);
  assert.equal(r.statusCode, 409);
  assert.match(r.json().error, /requeued/);
  await waitFor(() => state(id) === "awaiting_approval" && row(id).tested_sha !== old);
  assert.equal(row(id).target_sha, git(dir, "rev-parse", "main").trim());
  assert.equal((await approve(id, row(id).tested_sha)).statusCode, 200);
  assert.equal(items().length, 1);
});

test("a tag named like the target or the session branch does not shadow the branch", async () => {
  const { dir, session, run, approve, row } = await setup();
  const first = git(dir, "rev-parse", "main").trim();
  const a = await session({ "tag.txt": "x\n" });
  writeFileSync(join(dir, "m2.txt"), "m\n");
  git(dir, "add", "m2.txt");
  git(dir, "commit", "-q", "-m", "main moves");
  const tip = git(dir, "rev-parse", "main").trim();
  git(dir, "tag", "main", first); // `main` now names a tag AND a branch
  git(dir, "tag", a.wt.branch, first);
  const id = await run(a.taskId);
  assert.equal(row(id).state, "awaiting_approval", row(id).result);
  assert.equal(row(id).target_sha, tip, "the branch, not the tag");
  assert.equal(git(dir, "rev-parse", `${row(id).tested_sha}^`).trim(), tip);
  assert.equal((await approve(id, row(id).tested_sha)).statusCode, 200);
  assert.equal(git(dir, "rev-parse", "refs/heads/main").trim(), row(id).tested_sha);
});

test("an ignored .env already on disk is not overwritten by a merge that adds it", async () => {
  const { dir, session, run, approve, row } = await setup();
  const a = await session({ ".env": "FROM_AGENT=1\n" }); // force-added past .gitignore
  writeFileSync(join(dir, ".env"), "SECRET=keep\n");
  const id = await run(a.taskId);
  assert.equal(row(id).state, "awaiting_approval");
  const r = await approve(id, row(id).tested_sha);
  assert.equal(r.statusCode, 409);
  assert.match(r.json().error, /overwrite/);
  assert.equal(readFileSync(join(dir, ".env"), "utf8"), "SECRET=keep\n");
  assert.equal(row(id).state, "awaiting_approval");
});

test("a merge that adds a path under .vibe-worktrees/ is refused", async () => {
  const { session, run, approve, row } = await setup();
  const a = await session({ ".vibe-worktrees/x/evil.txt": "x\n" });
  const id = await run(a.taskId);
  const r = await approve(id, row(id).tested_sha);
  assert.equal(r.statusCode, 409);
  assert.match(r.json().error, /vibe-worktrees/);
});

test("dirty main checkout (tracked file) refuses the fast-forward", async () => {
  const { dir, session, run, approve, row } = await setup();
  const a = await session({ "d.txt": "x\n" });
  const id = await run(a.taskId);
  writeFileSync(join(dir, "a.txt"), "local edit\n");
  const r = await approve(id, row(id).tested_sha);
  assert.equal(r.statusCode, 409);
  assert.match(r.json().error, /uncommitted/);
  assert.equal(readFileSync(join(dir, "a.txt"), "utf8"), "local edit\n");
  git(dir, "checkout", "--", "a.txt");
  assert.equal((await approve(id, row(id).tested_sha)).statusCode, 200);
});

test("main checkout off the target branch refuses the fast-forward", async () => {
  const { dir, session, run, approve, row } = await setup();
  const a = await session({ "o.txt": "x\n" });
  const id = await run(a.taskId);
  git(dir, "checkout", "-q", "-b", "elsewhere");
  const r = await approve(id, row(id).tested_sha);
  assert.equal(r.statusCode, 409);
  assert.match(r.json().error, /not on main/);
});

test("a worktree whose .git file was redirected is refused (enqueue and worker)", async () => {
  const { dir, db, deps, session, enqueue, row, items } = await setup();
  const other = join(ROOT, `other${++n}`);
  mkdirSync(other);
  git(other, "init", "-q", "-b", "main");
  const a = await session({ "g.txt": "x\n" });
  writeFileSync(join(a.wt.path, ".git"), `gitdir: ${join(other, ".git")}\n`);
  const r = await enqueue(a.taskId);
  assert.equal(r.statusCode, 409);
  assert.match(r.json().error, /repo_layout_unsafe/);
  assert.equal(items().length, 0);

  // Same through the worker: a row that is already queued.
  const id = "11111111-1111-4111-8111-111111111111";
  db.prepare("INSERT INTO merge_queue (id, project_id, task_id, session_id, target, created_at, updated_at) VALUES (?,?,?,?,?,?,?)").run(
    id, "p1", a.taskId, a.sid, "main", new Date().toISOString(), new Date().toISOString(),
  );
  kick(deps, "p1");
  await waitFor(() => row(id).state === "bounced");
  assert.match(JSON.parse(row(id).result).reason, /repo_layout_unsafe/);
  assert.equal(existsSync(join(MERGE_DIR, id)), false);
});

test("enqueue preconditions", async () => {
  const { db, session, enqueue } = await setup();
  const a = await session({ "e.txt": "x\n" });
  assert.equal((await enqueue("nope")).statusCode, 404);
  db.prepare("UPDATE tasks SET state='running' WHERE id=?").run(a.taskId);
  assert.equal((await enqueue(a.taskId)).statusCode, 409);
  db.prepare("UPDATE tasks SET state='review' WHERE id=?").run(a.taskId);
  writeFileSync(join(a.wt.path, "dirty.txt"), "uncommitted\n");
  const dirty = await enqueue(a.taskId);
  assert.equal(dirty.statusCode, 409);
  assert.match(dirty.json().error, /commit first/);
  git(a.wt.path, "clean", "-fdq");
  db.prepare("UPDATE sessions SET target_branch=NULL WHERE id=?").run(a.sid);
  assert.equal((await enqueue(a.taskId)).statusCode, 409);
  db.prepare("UPDATE sessions SET target_branch='main' WHERE id=?").run(a.sid);
  assert.equal((await enqueue(a.taskId)).statusCode, 201);
  assert.equal((await enqueue(a.taskId)).statusCode, 409, "already queued");
});

test("worktree creation records the target branch; a detached HEAD has none", async () => {
  const dir = repo();
  assert.equal((await createWorktree(dir, "s_aaaaaaaaaaaa")).targetBranch, "main");
  git(dir, "checkout", "-q", "--detach");
  assert.equal((await createWorktree(dir, "s_bbbbbbbbbbbb")).targetBranch, null);
});

test("VIBE_MERGE_DIR unset: enqueue and the worker refuse with a clear error", async () => {
  const { db, deps, session, enqueue, row } = await setup();
  const a = await session({ "v.txt": "x\n" });
  delete process.env.VIBE_MERGE_DIR;
  try {
    const r = await enqueue(a.taskId);
    assert.equal(r.statusCode, 503);
    assert.match(r.json().error, /VIBE_MERGE_DIR/);
    const id = "22222222-2222-4222-8222-222222222222";
    db.prepare("INSERT INTO merge_queue (id, project_id, task_id, session_id, target, created_at, updated_at) VALUES (?,?,?,?,?,?,?)").run(
      id, "p1", a.taskId, a.sid, "main", new Date().toISOString(), new Date().toISOString(),
    );
    kick(deps, "p1");
    await waitFor(() => row(id).state === "bounced");
    assert.match(JSON.parse(row(id).result).reason, /VIBE_MERGE_DIR/);
  } finally {
    process.env.VIBE_MERGE_DIR = MERGE_DIR;
  }
});

test("restart recovery: an item left mid-rebase is aborted, cleaned and requeued", async () => {
  const { dir, db, deps, session, row } = await setup();
  const a = await session({ "rec.txt": "x\n" });
  const id = "33333333-3333-4333-8333-333333333333";
  db.prepare("INSERT INTO merge_queue (id, project_id, task_id, session_id, target, state, source_sha, created_at, updated_at) VALUES (?,?,?,?,?,'rebasing','deadbeef',?,?)").run(
    id, "p1", a.taskId, a.sid, "main", new Date().toISOString(), new Date().toISOString(),
  );
  // What a crash leaves: the scratch worktree stopped in a conflicted rebase.
  const scratch = join(MERGE_DIR, id);
  writeFileSync(join(dir, "c.txt"), "base\n");
  git(dir, "add", "c.txt");
  git(dir, "commit", "-q", "-m", "c base");
  git(dir, "branch", "left");
  git(dir, "checkout", "-q", "left");
  writeFileSync(join(dir, "c.txt"), "left\n");
  git(dir, "commit", "-qam", "left");
  git(dir, "checkout", "-q", "main");
  writeFileSync(join(dir, "c.txt"), "right\n");
  git(dir, "commit", "-qam", "right");
  git(dir, "worktree", "add", "-q", "--detach", scratch, "main");
  try {
    git(scratch, "rebase", "--onto", "main", "left~1", "left");
  } catch {
    /* conflict, as intended */
  }
  assert.ok(existsSync(join(scratch, ".git")));
  assert.match(git(scratch, "status"), /rebase in progress/);

  await recoverMergeQueue(deps);
  await waitFor(() => ["awaiting_approval", "bounced"].includes(row(id).state));
  assert.equal(row(id).state, "awaiting_approval", row(id).result);
  assert.equal(existsSync(scratch), false);
  assert.doesNotMatch(git(dir, "worktree", "list"), new RegExp(id));
  assert.ok((db.prepare("SELECT 1 FROM events WHERE kind='merge.requeue' AND detail LIKE '%restart'").get()));
});

test("reject, requeue, and the attempt limit", async () => {
  const { db, session, run, app, auth, row, state, taskState } = await setup();
  const msgs: string[] = [];
  const a = await session({ "q.txt": "x\n" }, { live: msgs });
  const id = await run(a.taskId);
  const post = (url: string) => app.inject({ method: "POST", url, headers: auth });
  assert.equal((await post(`/merge-queue/${id}/requeue`)).statusCode, 409, "only bounced items requeue");
  assert.equal((await post(`/merge-queue/${id}/reject`)).statusCode, 200);
  assert.equal(row(id).state, "bounced");
  assert.match(msgs[0], /rejected from the phone/);
  assert.equal(taskState(a.taskId), "review");
  const rq = await post(`/merge-queue/${id}/requeue`);
  assert.equal(rq.statusCode, 200, rq.body);
  assert.equal(rq.json().attempt, 2);
  await waitFor(() => state(id) === "awaiting_approval");
  assert.equal((await post(`/merge-queue/${id}/reject`)).statusCode, 200);
  db.prepare("UPDATE merge_queue SET attempt = 3 WHERE id = ?").run(id);
  const no = await post(`/merge-queue/${id}/requeue`);
  assert.equal(no.statusCode, 409);
  assert.match(no.json().error, /reset the task/);
  assert.equal((await post("/merge-queue/nope/reject")).statusCode, 404);
});

test("a session or task in the queue cannot be deleted or reset underneath it", async () => {
  const { app, auth, session, run, row } = await setup();
  const a = await session({ "k.txt": "x\n" });
  const id = await run(a.taskId);
  assert.equal(row(id).state, "awaiting_approval");
  assert.equal((await app.inject({ method: "DELETE", url: `/sessions/${a.sid}`, headers: auth })).statusCode, 409);
  assert.equal((await app.inject({ method: "DELETE", url: `/tasks/${a.taskId}`, headers: auth })).statusCode, 409);
  assert.equal((await app.inject({ method: "PUT", url: `/tasks/${a.taskId}`, headers: auth, payload: { state: "ready" } })).statusCode, 409);
  assert.equal((await app.inject({ method: "PUT", url: `/tasks/${a.taskId}`, headers: auth, payload: { state: "done" } })).statusCode, 409);
  await app.inject({ method: "POST", url: `/merge-queue/${id}/reject`, headers: auth });
  assert.notEqual((await app.inject({ method: "DELETE", url: `/sessions/${a.sid}`, headers: auth })).statusCode, 409);
});

test("project settings validation", async () => {
  const { app, auth, db, dir } = await setup(null);
  const put = (payload: unknown) => app.inject({ method: "PUT", url: "/projects/p1/settings", headers: auth, payload: payload as any });
  const get = async () => (await app.inject({ method: "GET", url: "/projects/p1/settings", headers: auth })).json();
  assert.deepEqual(await get(), { test_command: null });
  for (const bad of [
    "npm test", // a shell string
    ["./node", "x.js"], // relative
    ["/usr/bin/node", "x.js"], // absolute
    ["../node"],
    ["bash", "-c", "id"], // not a runner
    ["npm test"], // not a bare runner name
    ["npm", 3],
    ["node", "a\0b"],
    ["node", "x".repeat(257)],
    Array.from({ length: 33 }, () => "node"),
    [],
    [""],
  ]) assert.equal((await put({ test_command: bad })).statusCode, 400, JSON.stringify(bad).slice(0, 60));
  assert.equal((await put({})).statusCode, 400);
  assert.equal((await put({ test_command: ["node", "--test"] })).statusCode, 200);
  assert.deepEqual(await get(), { test_command: ["node", "--test"] });
  assert.ok(db.prepare("SELECT 1 FROM events WHERE kind = 'project.settings'").get());
  assert.equal((await app.inject({ method: "PUT", url: "/projects/nope/settings", headers: auth, payload: { test_command: null } })).statusCode, 404);
  assert.equal((await put({ test_command: null })).statusCode, 200);
  assert.deepEqual(await get(), { test_command: null });

  // A runner that resolves inside the repo is refused, even under an allowed name.
  const bin = join(dir, "node_modules", ".bin");
  mkdirSync(bin, { recursive: true });
  writeFileSync(join(bin, "npm"), "#!/bin/sh\nexit 0\n");
  chmodSync(join(bin, "npm"), 0o755);
  const saved = process.env.VIBE_TEST_PATH;
  process.env.VIBE_TEST_PATH = bin;
  try {
    const r = await put({ test_command: ["npm", "test"] });
    assert.equal(r.statusCode, 400);
    assert.match(r.json().error, /inside the project/);
  } finally {
    process.env.VIBE_TEST_PATH = saved;
  }
});

// ---- the test runner --------------------------------------------------------------------

function alive(pid: number): boolean {
  try {
    process.kill(pid, 0);
  } catch {
    return false;
  }
  try {
    return !/^\d+ \(.*\) Z/.test(readFileSync(`/proc/${pid}/stat`, "utf8"));
  } catch {
    return true;
  }
}
const scriptDir = mkdtempSync(join(tmpdir(), "vibe-mq-script-"));
function script(name: string, body: string): string {
  const f = join(scriptDir, name);
  writeFileSync(f, body);
  return f;
}
const GRANDCHILD = (pidFile: string) =>
  `const {spawn}=require("child_process");const g=spawn(process.execPath,["-e","setInterval(()=>{},1000)"],{stdio:"ignore"});` +
  `require("fs").writeFileSync(${JSON.stringify(pidFile)},String(g.pid));`;

test("test runner: a grandchild is killed when the run times out (process group)", async () => {
  const pidFile = join(scriptDir, "timeout.pid");
  const f = script("hang.cjs", GRANDCHILD(pidFile) + "setInterval(()=>{},1000);");
  const r = await runTestCommand(process.execPath, [f], scriptDir, 1000);
  assert.equal(r.timedOut, true);
  assert.equal(r.ok, false);
  const pid = Number(readFileSync(pidFile, "utf8"));
  await waitFor(() => !alive(pid), 3000);
});

test("test runner: a grandchild left behind by a run that exits is killed after exit", async () => {
  const pidFile = join(scriptDir, "exit.pid");
  const f = script("leave.cjs", GRANDCHILD(pidFile) + "process.exit(0);");
  const r = await runTestCommand(process.execPath, [f], scriptDir, 10_000);
  assert.equal(r.ok, true);
  await waitFor(() => !alive(Number(readFileSync(pidFile, "utf8"))), 3000);
});

test("test runner: env is allowlisted and output keeps only the last 64 KB", async () => {
  process.env.VIBE_SECRET_FOR_TEST = "leak";
  process.env.GIT_DIR = "/nope";
  try {
    const f = script("env.cjs", `process.stdout.write("x".repeat(200000));process.stdout.write("\\nTAIL "+JSON.stringify([process.env.VIBE_SECRET_FOR_TEST,process.env.GIT_DIR,process.env.CI]));`);
    const r = await runTestCommand(process.execPath, [f], scriptDir, 10_000);
    assert.equal(r.ok, true);
    assert.ok(r.output.length <= 64 * 1024);
    assert.match(r.output, /TAIL \[null,null,"1"\]/); // undefined stringifies to null
  } finally {
    delete process.env.VIBE_SECRET_FOR_TEST;
    delete process.env.GIT_DIR;
  }
});

// ---- review fixes ------------------------------------------------------------------------

test("approve: a worktree that can't follow rolls the branch back and tells the author", async () => {
  const { dir, session, run, approve, row, db } = await setup();
  const msgs: string[] = [];
  const a = await session({ "own.txt": "x\n" }, { live: msgs });
  writeFileSync(join(dir, "m.txt"), "from main\n");
  git(dir, "add", "m.txt");
  git(dir, "commit", "-q", "-m", "main adds m.txt");
  const id = await run(a.taskId);
  const it = row(id);
  assert.equal(it.state, "awaiting_approval");
  // Appears after enqueue: an untracked file read-tree would have to overwrite.
  writeFileSync(join(a.wt.path, "m.txt"), "local, uncommitted\n");
  const r = await approve(id, it.tested_sha);
  assert.equal(r.statusCode, 200, r.body);
  assert.equal(git(dir, "rev-parse", "main").trim(), it.tested_sha, "main is merged");
  assert.equal(git(dir, "rev-parse", a.wt.branch).trim(), it.source_sha, "author branch rolled back");
  assert.equal(git(a.wt.path, "diff", "--cached", "--name-only").trim(), "");
  assert.equal(readFileSync(join(a.wt.path, "m.txt"), "utf8"), "local, uncommitted\n");
  assert.match(JSON.parse(row(id).result).notes.join(" "), /not synced/);
  assert.equal(msgs.length, 1);
  assert.match(msgs[0], /not typed by the user/);
  assert.match(msgs[0], /NOT moved/);
  assert.equal((db.prepare("SELECT base_ref FROM sessions WHERE id = ?").get(a.sid) as any).base_ref !== it.tested_sha, true);
});

test("test runner: a detached grandchild holding the pipes can't hang the run", async () => {
  const t0 = Date.now();
  const r = await runTestCommand("/usr/bin/setsid", ["sh", "-c", "sleep 8"], scriptDir, 1000);
  assert.ok(Date.now() - t0 < 3500, `took ${Date.now() - t0} ms`);
  assert.equal(typeof r.output, "string");
});

test("reject landing while approve is mid-flight cannot bounce a fast-forwarded item", async () => {
  const { dir, deps, session, run, row, db } = await setup();
  const a = await session({ "race.txt": "x\n" });
  const id = await run(a.taskId);
  const sha = row(id).tested_sha;
  const p = approveItem(deps, id, sha, null); // runs until its first await
  await sleep(5);
  // Whatever stage approve is at, reject must either win cleanly (nothing merged) or lose.
  const rej = rejectItem(deps, id, null);
  const ap = await p;
  const main = git(dir, "rev-parse", "main").trim();
  const state = row(id).state;
  if (main === sha) {
    assert.equal(state, "merged");
    assert.equal(rej.ok, false);
  } else {
    assert.equal(state, "bounced");
    assert.equal(ap.ok, false);
  }
  assert.notEqual(state === "bounced" && main === sha, true);
  // Deterministic half: an item that is merging cannot be rejected.
  const b = await session({ "race2.txt": "x\n" });
  const id2 = await run(b.taskId);
  db.prepare("UPDATE merge_queue SET state='merging' WHERE id=?").run(id2);
  assert.equal(rejectItem(deps, id2, null).ok, false);
  assert.equal(row(id2).state, "merging");
});

test("restart recovery of a merging item: landed -> merged, not landed -> awaiting_approval", async () => {
  const { dir, deps, session, run, approve, row, db, taskState } = await setup();
  const a = await session({ "m1.txt": "x\n" });
  const id = await run(a.taskId);
  db.prepare("UPDATE merge_queue SET state='merging' WHERE id=?").run(id);
  await recoverMergeQueue(deps);
  assert.equal(row(id).state, "awaiting_approval", "ff never happened");
  assert.equal((await approve(id, row(id).tested_sha)).statusCode, 200);
  // Now pretend a crash right after the ff.
  const b = await session({ "m2.txt": "x\n" });
  const id2 = await run(b.taskId);
  git(dir, "merge", "--ff-only", row(id2).tested_sha);
  db.prepare("UPDATE merge_queue SET state='merging' WHERE id=?").run(id2);
  await recoverMergeQueue(deps);
  assert.equal(row(id2).state, "merged");
  assert.equal(taskState(b.taskId), "done");
});

test("approve and enqueue refuse a project outside the allowed roots", async () => {
  const { db, session, run, approve, row, enqueue } = await setup();
  const a = await session({ "root.txt": "x\n" });
  const id = await run(a.taskId);
  const outside = mkdtempSync(join(tmpdir(), "vibe-mq-outside-"));
  const orig = (db.prepare("SELECT path FROM projects WHERE id='p1'").get() as any).path;
  db.prepare("UPDATE projects SET path=? WHERE id='p1'").run(outside);
  try {
    assert.equal((await approve(id, row(id).tested_sha)).statusCode, 403);
    db.prepare("UPDATE merge_queue SET state='bounced' WHERE id=?").run(id);
    assert.equal((await enqueue(a.taskId)).statusCode, 403);
  } finally {
    db.prepare("UPDATE projects SET path=? WHERE id='p1'").run(orig);
  }
});

test("a driver planted in the project config: enqueue 409s and the worker bounces with repo_config_unsafe", async () => {
  const { dir, db, deps, session, enqueue, row } = await setup();
  const a = await session({ "drv.txt": "x\n" });
  git(dir, "config", "filter.x.clean", "/bin/cat");
  const r = await enqueue(a.taskId);
  assert.equal(r.statusCode, 409);
  assert.match(r.json().error, /repo_config_unsafe: filter\.x\.clean/);
  const id = "44444444-4444-4444-8444-444444444444";
  db.prepare("INSERT INTO merge_queue (id, project_id, task_id, session_id, target, created_at, updated_at) VALUES (?,?,?,?,?,?,?)").run(
    id, "p1", a.taskId, a.sid, "main", new Date().toISOString(), new Date().toISOString(),
  );
  kick(deps, "p1");
  await waitFor(() => row(id).state === "bounced");
  assert.match(JSON.parse(row(id).result).reason, /repo_config_unsafe/);
});
