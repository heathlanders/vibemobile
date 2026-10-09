// Read-only PR + CI status (proposal 45).

process.env.VIBE_PROJECT_ROOTS = "/home/user";
import test from "node:test";
import assert from "node:assert/strict";
import { openDb } from "./db.js";
import { buildApp } from "./app.js";
import { createPairingCode } from "./auth.js";
import { _clearCiCache, _setCiDepsForTest, fetchCi, parseGithubRepo, summarizeChecks, type CiDeps } from "./ci.js";

test("parseGithubRepo: only github.com remotes, in the forms git writes", () => {
  for (const [url, want] of [
    ["git@github.com:octocat/vibemobile.git", "octocat/vibemobile"],
    ["git@github.com:octocat/vibemobile", "octocat/vibemobile"],
    ["https://github.com/octocat/vibemobile.git", "octocat/vibemobile"],
    ["https://github.com/octocat/vibemobile/", "octocat/vibemobile"],
    ["ssh://git@github.com/o/r.git", "o/r"],
    ["  git@github.com:a-b/c.d_e.git\n", "a-b/c.d_e"],
  ] as const) assert.equal(parseGithubRepo(url), want, url);
  for (const bad of [
    "git@evil.com:o/r.git", "https://github.com.evil.com/o/r", "https://evil.com/github.com/o/r", "http://github.com/o/r",
    "git@github.com:o", "git@github.com:o/r/extra", "file:///etc/passwd", "ext::sh -c id", "-oProxyCommand=x", "",
    "git@github.com:-bad/r.git", "git@github.com:o/r;rm.git", "git@github.com:o/r name.git", "https://github.com/o/..",
  ]) assert.equal(parseGithubRepo(bad), null, JSON.stringify(bad));
});

test("summarizeChecks: CheckRun and StatusContext, urls only https, skipped ignored, overall state", () => {
  const run = (name: string, status: string, conclusion: string | null = null, url = "https://github.com/o/r/runs/1") => ({ __typename: "CheckRun", name, status, conclusion, detailsUrl: url });
  const ctx = (context: string, state: string) => ({ __typename: "StatusContext", context, state, targetUrl: "https://ci.example/x" });
  assert.deepEqual(summarizeChecks([run("build", "COMPLETED", "SUCCESS"), ctx("lint", "SUCCESS")]).state, "passing");
  assert.equal(summarizeChecks([run("build", "COMPLETED", "SUCCESS"), run("test", "COMPLETED", "FAILURE")]).state, "failing");
  assert.equal(summarizeChecks([run("build", "COMPLETED", "SUCCESS"), run("test", "IN_PROGRESS")]).state, "pending");
  assert.equal(summarizeChecks([run("a", "COMPLETED", "FAILURE"), run("b", "QUEUED")]).state, "failing", "a failure outranks pending");
  assert.equal(summarizeChecks([run("a", "COMPLETED", "SKIPPED")]).state, "none", "only skipped = nothing to report");
  assert.equal(summarizeChecks([run("a", "COMPLETED", "SKIPPED"), run("b", "COMPLETED", "NEUTRAL")]).state, "passing");
  assert.equal(summarizeChecks([ctx("ci", "PENDING")]).state, "pending");
  assert.equal(summarizeChecks([ctx("ci", "ERROR")]).state, "failing");
  for (const c of ["CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE"]) assert.equal(summarizeChecks([run("x", "COMPLETED", c)]).state, "failing", c);
  assert.equal(summarizeChecks([]).state, "none");
  const urls = summarizeChecks([run("a", "COMPLETED", "SUCCESS", "javascript:alert(1)"), run("b", "COMPLETED", "SUCCESS", "http://insecure"), run("c", "COMPLETED", "SUCCESS")]).checks.map((c) => c.url);
  assert.deepEqual(urls, [undefined, undefined, "https://github.com/o/r/runs/1"]);
});

test("summarizeChecks never throws on junk and caps the list", () => {
  for (const junk of [null, undefined, 5, "x", {}, [null, 3, "s", [], {}, { name: 5 }, { name: "" }]]) assert.doesNotThrow(() => summarizeChecks(junk), JSON.stringify(junk));
  assert.equal(summarizeChecks(Array.from({ length: 200 }, (_, i) => ({ name: `c${i}`, status: "COMPLETED", conclusion: "SUCCESS" }))).checks.length, 60);
});

function deps(over: { branch?: string; remote?: string; pr?: unknown; runs?: unknown; ghError?: Error; gitError?: boolean } = {}) {
  const ghCalls: string[][] = [];
  const d: CiDeps = {
    git: async (_cwd, argv) => {
      if (over.gitError) throw new Error("not a repo");
      return argv[0] === "rev-parse" ? (over.branch ?? "feat/x") + "\n" : (over.remote ?? "git@github.com:o/r.git") + "\n";
    },
    gh: async (argv) => {
      ghCalls.push(argv);
      if (over.ghError) throw over.ghError;
      return JSON.stringify(argv[0] === "pr" ? (over.pr ?? []) : (over.runs ?? []));
    },
  };
  return { d, ghCalls };
}
const PR = { number: 14, title: "Desktop client", state: "OPEN", url: "https://github.com/o/r/pull/14", isDraft: false, reviewDecision: "APPROVED", mergeStateStatus: "CLEAN", statusCheckRollup: [{ name: "build", status: "COMPLETED", conclusion: "SUCCESS", detailsUrl: "https://github.com/o/r/runs/9" }] };

test("an open PR: its details and checks, and exactly one fixed gh command", async () => {
  const { d, ghCalls } = deps({ pr: [PR] });
  const r = await fetchCi("/p", d);
  assert.ok(r.available);
  if (!r.available) return;
  assert.deepEqual([r.repo, r.branch, r.pr?.number, r.pr?.review, r.pr?.mergeState, r.checksState], ["o/r", "feat/x", 14, "APPROVED", "CLEAN", "passing"]);
  assert.deepEqual(ghCalls, [["pr", "list", "--repo", "o/r", "--head", "feat/x", "--state", "all", "--limit", "1", "--json", "number,title,state,url,isDraft,reviewDecision,mergeStateStatus,statusCheckRollup"]]);
});

test("no PR: falls back to the branch's latest workflow runs", async () => {
  const { d, ghCalls } = deps({ pr: [], runs: [{ name: "CI", status: "completed", conclusion: "failure", url: "https://github.com/o/r/actions/runs/1", createdAt: "2026-10-07T10:00:00Z", headBranch: "feat/x" }] });
  const r = await fetchCi("/p", d);
  assert.ok(r.available);
  if (!r.available) return;
  assert.equal(r.pr, null);
  assert.deepEqual(r.runs.map((x) => [x.name, x.state]), [["CI", "failing"]]);
  assert.equal(r.checksState, "failing");
  assert.deepEqual(ghCalls[1], ["run", "list", "--repo", "o/r", "--branch", "feat/x", "--limit", "5", "--json", "name,status,conclusion,url,createdAt,headBranch"]);
});

test("no PR and no runs → available, checksState none", async () => {
  const r = await fetchCi("/p", deps().d);
  assert.ok(r.available && r.pr === null && r.runs.length === 0 && r.checksState === "none");
});

test("unavailable cases never reach gh: not GitHub, detached HEAD, odd branch names, not a repo", async () => {
  for (const [over, why] of [
    [{ remote: "git@gitlab.com:o/r.git" }, /not a GitHub repository/],
    [{ remote: "https://github.com.evil.com/o/r" }, /not a GitHub repository/],
    [{ branch: "HEAD" }, /detached HEAD/],
    [{ branch: "-oops" }, /detached HEAD/],
    [{ branch: "a b" }, /detached HEAD/],
    [{ branch: "x;rm -rf /" }, /detached HEAD/],
    [{ branch: "$(id)" }, /detached HEAD/],
    [{ gitError: true }, /not a git repository/],
  ] as const) {
    const { d, ghCalls } = deps(over as any);
    const r = await fetchCi("/p", d);
    assert.equal(r.available, false, JSON.stringify(over));
    assert.match((r as { reason: string }).reason, why, JSON.stringify(over));
    assert.equal(ghCalls.length, 0, `gh must not be called for ${JSON.stringify(over)}`);
  }
});

test("gh failures become one of a few fixed, non-leaky reasons", async () => {
  for (const [msg, want] of [
    [Object.assign(new Error("spawn gh ENOENT"), {}), /not installed/],
    [Object.assign(new Error("x"), { stderr: "To get started with GitHub CLI, please run: gh auth login" }), /not signed in/],
    [Object.assign(new Error("x"), { stderr: "HTTP 403: Resource not accessible" }), /not signed in/],
    [Object.assign(new Error("x"), { stderr: "GraphQL: Could not resolve to a Repository with the name 'o/r'" }), /not found/],
    [Object.assign(new Error("x"), { stderr: "dial tcp 10.0.0.1:443: i/o timeout /home/user/.config/gh/hosts.yml" }), /could not reach GitHub/],
  ] as const) {
    const r = await fetchCi("/p", deps({ ghError: msg as Error }).d);
    assert.equal(r.available, false);
    assert.match((r as { reason: string }).reason, want);
    assert.doesNotMatch((r as { reason: string }).reason, /\/home|hosts\.yml|10\.0\.0/, "no paths or hosts from gh's error");
  }
});

test("a PR with hostile text is clipped and its url must be https", async () => {
  const r = await fetchCi("/p", deps({ pr: [{ ...PR, title: "t".repeat(1000), url: "javascript:alert(1)", reviewDecision: null }] }).d);
  assert.ok(r.available);
  if (!r.available) return;
  assert.equal(r.pr!.title.length, 200);
  assert.equal(r.pr!.url, "");
  assert.equal(r.pr!.review, null);
});

// ---- routes -----------------------------------------------------------------------------------------

async function setup() {
  _clearCiCache();
  const db = openDb(":memory:");
  const app = await buildApp(db);
  const { token } = (await app.inject({ method: "POST", url: "/pair", payload: { code: createPairingCode(db), device_name: "t" } })).json();
  const auth = { authorization: `Bearer ${token}` };
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES ('p','/home/user/vibemobile','p','unknown')").run();
  db.prepare("INSERT INTO sessions (id, project_id, kind, status, created_at) VALUES ('s','p','claude','live',?)").run(new Date().toISOString());
  const get = (url: string, headers: Record<string, string> = auth) => app.inject({ method: "GET", url, headers });
  return { db, get };
}
test.afterEach(() => _setCiDepsForTest(null));

test("GET /projects/:id/ci and /sessions/:id/ci return the status; the second call within 30 s is cached", async () => {
  const { get } = await setup();
  const { d, ghCalls } = deps({ pr: [PR] });
  _setCiDepsForTest(d);
  const a = await get("/projects/p/ci");
  assert.equal(a.statusCode, 200);
  assert.equal(a.json().pr.number, 14);
  const n = ghCalls.length;
  assert.equal((await get("/sessions/s/ci")).statusCode, 200);
  assert.equal(ghCalls.length, n, "same checkout, served from the cache — no second GitHub call");
});

test("a session in a worktree reads ITS checkout's branch", async () => {
  const { get, db } = await setup();
  db.prepare("UPDATE sessions SET worktree_path = '/home/user/vibemobile/.vibe-worktrees/s_abc' WHERE id = 's'").run();
  const cwds: string[] = [];
  _setCiDepsForTest({ ...deps({ pr: [PR] }).d, git: async (cwd, argv) => (cwds.push(cwd), argv[0] === "rev-parse" ? "vibe/s_abc\n" : "git@github.com:o/r.git\n") });
  const r = await get("/sessions/s/ci");
  assert.equal(r.json().branch, "vibe/s_abc");
  assert.ok(cwds.every((c) => c.endsWith("/.vibe-worktrees/s_abc")));
});

test("unknown project/session 404, a project outside the allowed roots 403, no token 401", async () => {
  const { get, db } = await setup();
  _setCiDepsForTest(deps().d);
  assert.equal((await get("/projects/nope/ci")).statusCode, 404);
  assert.equal((await get("/sessions/nope/ci")).statusCode, 404);
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES ('out','/etc','o','unknown')").run();
  assert.equal((await get("/projects/out/ci")).statusCode, 403);
  assert.equal((await get("/projects/p/ci", {})).statusCode, 401);
});
