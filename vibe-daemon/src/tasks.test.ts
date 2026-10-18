// Swarm tasks + file leases (proposal 65). Real temp git repos for dispatch (worktrees),
// a fake Agent SDK for the engine, in-memory DB.

import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const ROOT = mkdtempSync(join(tmpdir(), "vibe-tasks-"));
process.env.VIBE_PROJECT_ROOTS = ROOT;
process.env.VIBE_CLAUDE_PROJECTS_DIR = "/nonexistent/vibe-test-claude-projects";

import { openDb } from "./db.js";
import { buildApp } from "./app.js";
import { createPairingCode } from "./auth.js";
import { ClaudeSession, type ClaudeRegistry } from "./claude.js";
import { claimTaskTool, createPeerServer } from "./peer-tools.js";
import { claimTask, completeTask, leasedToolPath, entriesOverlap, normalizeScope, listTasksText, reserveTask } from "./tasks.js";

const git = (cwd: string, ...a: string[]) => execFileSync("git", a, { cwd, stdio: "pipe" }).toString();
let n = 0;
function repo() {
  const dir = join(ROOT, `r${++n}`);
  mkdirSync(dir);
  git(dir, "init", "-q", "-b", "main");
  writeFileSync(join(dir, "a.txt"), "one\n");
  git(dir, "add", "-A");
  git(dir, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "init");
  return dir;
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
async function waitFor(fn: () => boolean, ms = 2000) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) {
    if (fn()) return;
    await sleep(5);
  }
  throw new Error("timed out waiting for condition");
}

// Fake Agent SDK: records every call; consumes the first user turn.
function fakeSdk() {
  const calls: { prompts: string[]; options: any }[] = [];
  const fn = (params: { prompt: AsyncIterable<any>; options: any }) => {
    const rec = { prompts: [] as string[], options: params.options };
    calls.push(rec);
    return (async function* () {
      yield { type: "system", subtype: "init", session_id: "c1", model: "m" };
      for await (const m of params.prompt) {
        rec.prompts.push(typeof m.message?.content === "string" ? m.message.content : JSON.stringify(m.message?.content));
        yield { type: "result", subtype: "success", total_cost_usd: 0 };
      }
    })();
  };
  return { fn, calls };
}

async function setup(projectPath = repo()) {
  const db = openDb(":memory:");
  const registry: ClaudeRegistry = new Map();
  const sdk = fakeSdk();
  const tmux: any = { hasSession: async () => true, createSession: async () => {}, killSession: async () => {} };
  const app = await buildApp(db, tmux, registry, sdk.fn);
  const { token } = (
    await app.inject({ method: "POST", url: "/pair", payload: { code: createPairingCode(db), device_name: "t" } })
  ).json();
  const auth = { authorization: `Bearer ${token}` };
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES (?,?,?,?)").run("p1", projectPath, "p", "unknown");
  const mk = async (title: string, extra: Record<string, unknown> = {}) => {
    const r = await app.inject({ method: "POST", url: "/projects/p1/tasks", headers: auth, payload: { title, ...extra } });
    assert.equal(r.statusCode, 201, r.body);
    return r.json();
  };
  const dispatch = (id: string) => app.inject({ method: "POST", url: `/tasks/${id}/dispatch`, headers: auth });
  return { db, app, auth, registry, sdk, mk, dispatch };
}

function addSession(db: any, id: string, wt: string | null = "/wt/" + id, projectId = "p1") {
  db.prepare("INSERT INTO sessions (id, project_id, kind, status, created_at, worktree_path) VALUES (?,?,?,?,?,?)").run(
    id, projectId, "claude", "live", new Date().toISOString(), wt,
  );
}

test("scope normalisation and validation", () => {
  assert.deepEqual(normalizeScope(["./src//a/", " b.ts ", "src/a", ""]), ["src/a", "b.ts"]);
  for (const bad of ["../x", "a/../b", "/etc", ".git", "a/.git/config", ".GIT/x", "a\\b", ".", "./"]) {
    assert.ok("error" in (normalizeScope([bad]) as any), bad);
  }
  assert.ok("error" in (normalizeScope("src") as any));
  assert.ok("error" in (normalizeScope([3]) as any));
  assert.ok(Array.isArray(normalizeScope(Array.from({ length: 50 }, (_, i) => `d${i}`))));
  assert.ok("error" in (normalizeScope(Array.from({ length: 51 }, (_, i) => `d${i}`)) as any));
  assert.ok("error" in (normalizeScope(["a".repeat(513)]) as any));
  assert.ok(Array.isArray(normalizeScope(["a".repeat(512)])));
});

test("overlap is per path segment", () => {
  assert.equal(entriesOverlap("src/a", "src/a/b.ts"), true);
  assert.equal(entriesOverlap("src/a/b.ts", "src/a"), true);
  assert.equal(entriesOverlap("src/a", "src/a"), true);
  assert.equal(entriesOverlap("src/a", "src/ab.ts"), false);
  assert.equal(entriesOverlap("src", "lib"), false);
});

test("task CRUD, validation and state edits over REST", async () => {
  const { app, auth, mk } = await setup();
  const t = await mk("First", { body: "goal", scope: ["src/a/"], deps: [] });
  assert.equal(t.state, "ready");
  assert.deepEqual(t.scope, ["src/a"]);
  const dep = await mk("Second", { deps: [t.id] });
  assert.deepEqual(dep.deps, [t.id]);

  const list = (await app.inject({ method: "GET", url: "/projects/p1/tasks", headers: auth })).json();
  assert.deepEqual(list.map((x: any) => x.id), [t.id, dep.id]);

  const put = (id: string, payload: unknown) => app.inject({ method: "PUT", url: `/tasks/${id}`, headers: auth, payload: payload as any });
  const upd = await put(t.id, { title: "Renamed", scope: ["lib"] });
  assert.equal(upd.statusCode, 200);
  assert.equal(upd.json().title, "Renamed");
  assert.deepEqual(upd.json().scope, ["lib"]);

  const post = (payload: unknown) => app.inject({ method: "POST", url: "/projects/p1/tasks", headers: auth, payload: payload as any });
  assert.equal((await post({})).statusCode, 400);
  assert.equal((await post({ title: "x", scope: ["../x"] })).statusCode, 400);
  assert.equal((await post({ title: "x", scope: ["/etc"] })).statusCode, 400);
  assert.equal((await post({ title: "x", scope: [".git/hooks"] })).statusCode, 400);
  assert.equal((await post({ title: "x", deps: ["nope"] })).statusCode, 400);
  assert.equal((await put(t.id, { deps: [t.id] })).statusCode, 400);
  assert.equal((await put(t.id, { state: "running" })).statusCode, 400);
  assert.equal((await put(t.id, { state: "done" })).statusCode, 409, "done only from review");
  assert.equal((await put("nope", { title: "x" })).statusCode, 404);
  assert.equal((await app.inject({ method: "GET", url: "/projects/nope/tasks", headers: auth })).statusCode, 404);

  assert.equal((await app.inject({ method: "DELETE", url: `/tasks/${t.id}`, headers: auth })).statusCode, 204);
  assert.equal((await app.inject({ method: "DELETE", url: `/tasks/${t.id}`, headers: auth })).statusCode, 204);
});

test("dispatch refusals each name the blocker (409)", async () => {
  const { db, mk, dispatch } = await setup();
  const base = await mk("Base", { scope: ["src/a"] });
  const child = await mk("Child", { scope: ["docs"], deps: [base.id] });
  const clash = await mk("Clash", { scope: ["src/a/b.ts"] });

  let r = await dispatch(child.id);
  assert.equal(r.statusCode, 409);
  assert.match(r.json().error, /Base/);
  assert.match(r.json().error, new RegExp(base.id));

  // Simulate a running holder, then dispatch an overlapping task.
  db.prepare("UPDATE tasks SET state='running', session_id='sX' WHERE id=?").run(base.id);
  r = await dispatch(clash.id);
  assert.equal(r.statusCode, 409);
  assert.match(r.json().error, /overlaps task 'Base'/);

  r = await dispatch(base.id);
  assert.equal(r.statusCode, 409);
  assert.match(r.json().error, /not ready/);

  assert.equal((await dispatch("nope")).statusCode, 404);
});

test("dispatch: VIBE_SWARM_MAX default 3 caps running tasks", async () => {
  const { db, mk, dispatch } = await setup();
  assert.equal(process.env.VIBE_SWARM_MAX, undefined);
  for (let i = 0; i < 3; i++) {
    const t = await mk(`T${i}`, { scope: [`d${i}`] });
    db.prepare("UPDATE tasks SET state='running', session_id='sX' WHERE id=?").run(t.id);
  }
  const fourth = await mk("Fourth", { scope: ["other"] });
  const r = await dispatch(fourth.id);
  assert.equal(r.statusCode, 409);
  assert.match(r.json().error, /swarm limit/);
  assert.match(r.json().error, /T0/);
});

test("dispatch creates a worktree session and starts the first turn with no client attached", async () => {
  const { db, registry, sdk, mk, dispatch, app, auth } = await setup();
  const t = await mk("Add widget", { body: "make a widget", scope: ["src/w"] });
  const r = await dispatch(t.id);
  assert.equal(r.statusCode, 200, r.body);
  const { task, session_id } = r.json();
  assert.equal(task.state, "running");
  assert.equal(task.session_id, session_id);

  const row = db.prepare("SELECT * FROM sessions WHERE id = ?").get(session_id) as any;
  assert.ok(row.worktree_path, "worktree session");
  assert.equal(row.kind, "claude");
  assert.ok(registry.has(session_id), "engine started server-side");

  await waitFor(() => sdk.calls.length === 1 && sdk.calls[0].prompts.length === 1);
  assert.match(sdk.calls[0].prompts[0], /Add widget/);
  assert.match(sdk.calls[0].prompts[0], /make a widget/);
  assert.match(sdk.calls[0].prompts[0], /src\/w/);
  assert.match(sdk.calls[0].prompts[0], /complete_task/);
  assert.equal(sdk.calls[0].options.cwd, row.worktree_path);
  assert.equal((db.prepare("SELECT initial_prompt FROM sessions WHERE id=?").get(session_id) as any).initial_prompt, null);
  assert.ok(db.prepare("SELECT 1 FROM events WHERE kind='task.dispatch'").get());

  // Back to ready releases the lease and the session link.
  const back = await app.inject({ method: "PUT", url: `/tasks/${t.id}`, headers: auth, payload: { state: "ready" } });
  assert.equal(back.json().state, "ready");
  assert.equal(back.json().session_id, null);
  registry.get(session_id)?.stop();
});

test("done broadcasts the changed files to the project's other live sessions (S4)", async () => {
  const { db, registry, sdk, mk, dispatch, app, auth } = await setup();
  const t = await mk("Add widget", { scope: ["src/w"] });
  const { session_id } = (await dispatch(t.id)).json();
  const wt = (db.prepare("SELECT worktree_path FROM sessions WHERE id = ?").get(session_id) as any).worktree_path;
  mkdirSync(join(wt, "src/w"), { recursive: true });
  writeFileSync(join(wt, "src/w/x.ts"), "x\n");
  git(wt, "add", "-A");
  git(wt, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "w");

  const got: Record<string, string[]> = { s2: [], s3: [] };
  for (const id of ["s2", "s3"]) registry.set(id, { pushUser: (x: string) => got[id].push(x) } as any);
  addSession(db, "s2", null);
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES (?,?,?,?)").run("p2", "/x", "q", "unknown");
  addSession(db, "s3", null, "p2");

  db.prepare("UPDATE tasks SET state='review' WHERE id=?").run(t.id);
  const r = await app.inject({ method: "PUT", url: `/tasks/${t.id}`, headers: auth, payload: { state: "done" } });
  assert.equal(r.json().state, "done");
  await waitFor(() => got.s2.length === 1);
  assert.match(got.s2[0], /not typed by the user/);
  assert.match(got.s2[0], /Add widget/);
  assert.match(got.s2[0], /src\/w\/x\.ts/);
  assert.match(got.s2[0], /rebase|pull/);
  assert.equal(got.s3.length, 0, "other project not told");
  await sleep(50);
  assert.ok(!sdk.calls.flatMap((c) => c.prompts).some((p) => /was merged/.test(p)), "owner not told");
  assert.ok(db.prepare("SELECT 1 FROM events WHERE kind='task.broadcast'").get());
  registry.get(session_id)?.stop();
});

test("dispatch failure (session cap) releases the task back to ready", async () => {
  const { db, mk, dispatch } = await setup();
  const prev = process.env.VIBE_MAX_CLAUDE;
  process.env.VIBE_MAX_CLAUDE = "0";
  try {
    const t = await mk("Capped", { scope: ["x"] });
    const r = await dispatch(t.id);
    assert.equal(r.statusCode, 429);
    assert.equal((db.prepare("SELECT state, session_id FROM tasks WHERE id=?").get(t.id) as any).state, "ready");
  } finally {
    if (prev === undefined) delete process.env.VIBE_MAX_CLAUDE;
    else process.env.VIBE_MAX_CLAUDE = prev;
  }
});

test("claim_task race: exactly one winner", async () => {
  const { db, mk } = await setup();
  const t = await mk("Contested", { scope: ["src/a"] });
  addSession(db, "s1");
  addSession(db, "s2");
  const rs = await Promise.all([Promise.resolve(claimTask(db, "s1", t.id)), Promise.resolve(claimTask(db, "s2", t.id))]);
  assert.equal(rs.filter((r) => r.ok).length, 1);
  const loser = rs.find((r) => !r.ok) as any;
  assert.match(loser.error, /not ready/);
  const row = db.prepare("SELECT state, session_id FROM tasks WHERE id=?").get(t.id) as any;
  assert.equal(row.state, "running");
  assert.ok(["s1", "s2"].includes(row.session_id));
});

test("claim_task: needs a worktree, refused in plan mode, same-project, overlap checked", async () => {
  const { db, mk } = await setup();
  const t = await mk("T", { scope: ["src"] });
  const other = await mk("Other", { scope: ["src/x"] });
  addSession(db, "plain", null);
  addSession(db, "s1");
  assert.match((claimTask(db, "plain", t.id) as any).error, /worktree/);
  assert.match((claimTaskTool({ db, registry: new Map(), selfId: "s1", getMode: () => "plan" }, t.id) as any).error, /plan mode/);
  assert.match((claimTask(db, "ghost", t.id) as any).error, /registered/);
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES (?,?,?,?)").run("p2", "/x", "q", "unknown");
  addSession(db, "foreign", "/wt/f", "p2");
  assert.match((claimTask(db, "foreign", t.id) as any).error, /no such task/);
  assert.equal(claimTask(db, "s1", t.id).ok, true);
  assert.match((claimTask(db, "s1", other.id) as any).error, /overlaps task 'T'/);
  assert.ok(db.prepare("SELECT 1 FROM events WHERE kind='task.claim'").get());
});

test("complete_task: only the owner; moves to review and appends the result", async () => {
  const { db, mk } = await setup();
  const t = await mk("Work", { body: "goal", scope: ["a"] });
  addSession(db, "s1");
  addSession(db, "s2");
  assert.equal(claimTask(db, "s1", t.id).ok, true);
  assert.match((completeTask(db, "s2", t.id, "stolen") as any).error, /only the session that owns/);
  assert.equal((db.prepare("SELECT state FROM tasks WHERE id=?").get(t.id) as any).state, "running");
  assert.equal(completeTask(db, "s1", t.id, "all done").ok, true);
  const row = db.prepare("SELECT state, body FROM tasks WHERE id=?").get(t.id) as any;
  assert.equal(row.state, "review");
  assert.equal(row.body, "goal\n\n## Result\nall done");
  assert.match((completeTask(db, "s1", t.id, "again") as any).error, /not running/);
  assert.match(listTasksText(db, "s1").ok ? (listTasksText(db, "s1") as any).text : "", /\[review\]/);
});

test("list_tasks flags READY only when deps are done and nothing overlapping is held", async () => {
  const { db, mk } = await setup();
  const a = await mk("A", { scope: ["x"] });
  await mk("B", { scope: ["x/y"] });
  const c = await mk("C", { scope: ["z"], deps: [a.id] });
  const d = await mk("D", { scope: ["w"] });
  addSession(db, "s1");
  assert.equal(reserveTask(db, a.id, "s1").ok, true);
  const text = (listTasksText(db, "s1") as any).text as string;
  const line = (title: string) => text.split("\n").find((l) => l.startsWith("- ") && l.includes(` ${title}`))!;
  assert.doesNotMatch(line("B"), /READY/);
  assert.doesNotMatch(line("C"), /READY/);
  assert.match(line("D"), /READY/);
  assert.ok(c && d);
});

test("peer server registers the task tools", () => {
  const { db } = { db: openDb(":memory:") };
  const srv: any = createPeerServer({ db, registry: new Map(), selfId: "s", getMode: () => "auto" });
  assert.ok(srv);
});

// ---- lease enforcement in canUseTool ----------------------------------------

function leaseSetup() {
  const db = openDb(":memory:");
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES (?,?,?,?)").run("p1", "/proj", "p", "unknown");
  addSession(db, "holder", "/proj/.vibe-worktrees/holder");
  addSession(db, "other", null);
  db.prepare(
    "INSERT INTO tasks (id, project_id, title, scope, state, session_id, created_at, updated_at) VALUES ('t1','p1','Refactor A','[\"src/a\"]','running','holder','x','x')",
  ).run();
  return db;
}

async function decide(db: any, sid: string, cwd: string, tool: string, input: Record<string, unknown>) {
  let out: any;
  const fn = (params: { prompt: AsyncIterable<any>; options: any }) =>
    (async function* () {
      yield { type: "system", subtype: "init", session_id: "c", model: "m" };
      await params.prompt[Symbol.asyncIterator]().next();
      out = await params.options.canUseTool(tool, input, { toolUseID: "tu" });
      yield { type: "result", subtype: "success", total_cost_usd: 0 };
    })();
  const s = new ClaudeSession(db, sid, cwd, fn as any);
  s.start();
  s.pushUser("go");
  await waitFor(() => out !== undefined);
  s.stop();
  return out;
}

test("lease: non-holder is denied, holder allowed, allowed after done", async () => {
  const db = leaseSetup();
  const deny = await decide(db, "other", "/proj", "Edit", { file_path: "/proj/src/a/b.ts" });
  assert.equal(deny.behavior, "deny");
  assert.match(deny.message, /src\/a\/b\.ts is leased by task 'Refactor A' \(session holder\)/);
  assert.match(deny.message, /send_message/);
  assert.ok(db.prepare("SELECT 1 FROM events WHERE kind='lease.deny'").get());

  for (const [tool, input] of [
    ["Write", { file_path: "src/a/new.ts" }],
    ["MultiEdit", { file_path: "/proj/src/a" }],
    ["NotebookEdit", { notebook_path: "/proj/src/a/n.ipynb" }],
  ] as const) {
    assert.equal((await decide(db, "other", "/proj", tool, input as any)).behavior, "deny", tool);
  }

  // Not leased: sibling by prefix, a read tool, a path outside the checkout.
  for (const [tool, input] of [
    ["Edit", { file_path: "/proj/src/ab.ts" }],
    ["Read", { file_path: "/proj/src/a/b.ts" }],
  ] as const) {
    assert.equal((await decide(db, "other", "/proj", tool, input as any)).behavior, "allow", `${tool} ${JSON.stringify(input)}`);
  }

  // Outside the checkout is not leased (the normal file-scope check handles it).
  assert.equal(leasedToolPath("Edit", { file_path: "/elsewhere/src/a/b.ts" }, "/proj"), null);
  assert.equal(leasedToolPath("Edit", { file_path: "../x/src/a/b.ts" }, "/proj"), null);
  assert.equal(leasedToolPath("Edit", { file_path: "/proj/src/a/b.ts" }, "/proj"), "src/a/b.ts");

  // The holder is never blocked (its checkout is its worktree).
  const mine = await decide(db, "holder", "/proj/.vibe-worktrees/holder", "Edit", { file_path: "/proj/.vibe-worktrees/holder/src/a/b.ts" });
  assert.equal(mine.behavior, "allow");

  // Review still holds the lease; done lifts it.
  db.prepare("UPDATE tasks SET state='review'").run();
  assert.equal((await decide(db, "other", "/proj", "Edit", { file_path: "src/a/b.ts" })).behavior, "deny");
  db.prepare("UPDATE tasks SET state='done'").run();
  assert.equal((await decide(db, "other", "/proj", "Edit", { file_path: "src/a/b.ts" })).behavior, "allow");
});

test("lease: only other sessions in the same project are blocked", async () => {
  const db = leaseSetup();
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES (?,?,?,?)").run("p2", "/proj2", "q", "unknown");
  addSession(db, "foreign", null, "p2");
  assert.equal((await decide(db, "foreign", "/proj2", "Edit", { file_path: "src/a/b.ts" })).behavior, "allow");
});
