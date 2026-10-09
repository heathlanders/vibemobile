// Pull request + CI status for a project's / session's branch (proposal 45). READ-ONLY.
//
// The daemon already has the user's GitHub login on this box (`gh`). This module only ever runs
// two *list* commands — no create, comment, merge, push, or auth change:
//   gh pr list  --repo O/R --head BRANCH --state all --limit 1 --json …
//   gh run list --repo O/R --branch BRANCH --limit 5 --json …        (only when there is no PR)
// Hardening, because the agent can write .git/config:
//   - git reads go through gitRun (hooks/config code-exec knobs neutralised, ADR 0024);
//   - O/R is parsed from the origin URL with a strict regex and only for github.com — anything
//     else is "not a GitHub repository", never passed on;
//   - the branch must match a conservative pattern and can't start with "-";
//   - gh is run with an ARRAY argv, a scrubbed GIT_* env, no prompts, a timeout and an output cap;
//   - the answer contains only names/states/URLs of the repo — never tokens or gh config;
//   - results are cached for 30 s so a polling phone can't hammer the GitHub API.

import { execFile } from "node:child_process";
import { promisify } from "node:util";
import type { FastifyInstance } from "fastify";
import type { DB } from "./db.js";
import { gitEnv, gitRun } from "./git-run.js";
import { pathInRoots } from "./paths.js";

const exec = promisify(execFile);

export type CiCheck = { name: string; state: "passing" | "failing" | "pending" | "skipped"; url?: string };
export type CiState = "passing" | "failing" | "pending" | "none";
export type CiPr = { number: number; title: string; state: string; url: string; isDraft: boolean; review: string | null; mergeState: string | null };
export type CiRun = { name: string; state: CiCheck["state"]; branch: string; url?: string; createdAt?: string };
export type CiResult =
  | { available: false; reason: string }
  | { available: true; repo: string; branch: string; pr: CiPr | null; checks: CiCheck[]; checksState: CiState; runs: CiRun[] };

export type CiDeps = {
  git: (cwd: string, argv: string[]) => Promise<string>;
  gh: (argv: string[]) => Promise<string>;
};

const BRANCH = /^[A-Za-z0-9][A-Za-z0-9._/-]{0,199}$/;
const OWNER_REPO = /^([A-Za-z0-9][A-Za-z0-9-]{0,38})\/([A-Za-z0-9._-]{1,100})$/;

/** "git@github.com:o/r.git" | "https://github.com/o/r" → "o/r"; anything else → null. */
export function parseGithubRepo(url: string): string | null {
  const m = /^(?:git@github\.com:|https:\/\/github\.com\/|ssh:\/\/git@github\.com\/)([^/\s]+)\/([^/\s]+?)(?:\.git)?\/?$/.exec(url.trim());
  if (!m) return null;
  const slug = `${m[1]}/${m[2]}`;
  return OWNER_REPO.test(slug) && !m[2].endsWith(".") ? slug : null;
}

const str = (x: unknown, n = 200): string => (typeof x === "string" ? x.slice(0, n) : "");
const httpUrl = (x: unknown): string | undefined => (typeof x === "string" && /^https:\/\/[^\s]+$/.test(x) ? x.slice(0, 400) : undefined);

const FAIL = new Set(["FAILURE", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE", "ERROR", "STALE"]);
const OK = new Set(["SUCCESS", "NEUTRAL"]);
function checkState(status: unknown, conclusion: unknown): CiCheck["state"] {
  const s = str(status).toUpperCase();
  const c = str(conclusion).toUpperCase();
  if (s && s !== "COMPLETED") return "pending"; // QUEUED / IN_PROGRESS / WAITING / PENDING
  if (FAIL.has(c)) return "failing";
  if (c === "SKIPPED") return "skipped";
  if (OK.has(c)) return "passing";
  return "pending"; // completed with a conclusion we don't know, or none yet
}

/** statusCheckRollup items are CheckRun {name,status,conclusion,detailsUrl} or StatusContext {context,state,targetUrl}. */
export function summarizeChecks(rollup: unknown): { checks: CiCheck[]; state: CiState } {
  const checks: CiCheck[] = [];
  for (const raw of Array.isArray(rollup) ? rollup.slice(0, 60) : []) {
    const c = raw as Record<string, unknown> | null;
    if (!c || typeof c !== "object") continue;
    const isContext = typeof c.context === "string";
    const name = str(isContext ? c.context : c.name, 120);
    if (!name) continue;
    const state: CiCheck["state"] = isContext
      ? FAIL.has(str(c.state).toUpperCase()) ? "failing" : str(c.state).toUpperCase() === "SUCCESS" ? "passing" : "pending"
      : checkState(c.status, c.conclusion);
    checks.push({ name, state, ...(httpUrl(isContext ? c.targetUrl : c.detailsUrl) ? { url: httpUrl(isContext ? c.targetUrl : c.detailsUrl) } : {}) });
  }
  const live = checks.filter((c) => c.state !== "skipped");
  const state: CiState = !live.length ? "none" : live.some((c) => c.state === "failing") ? "failing" : live.some((c) => c.state === "pending") ? "pending" : "passing";
  return { checks, state };
}

const json = (s: string): unknown => {
  try {
    return JSON.parse(s);
  } catch {
    return null;
  }
};

export async function fetchCi(cwd: string, deps: CiDeps): Promise<CiResult> {
  let branch: string;
  let repo: string | null;
  try {
    branch = (await deps.git(cwd, ["rev-parse", "--abbrev-ref", "HEAD"])).trim();
    repo = parseGithubRepo(await deps.git(cwd, ["config", "--get", "remote.origin.url"]));
  } catch {
    return { available: false, reason: "not a git repository with an origin remote" };
  }
  if (!repo) return { available: false, reason: "origin is not a GitHub repository" };
  if (branch === "HEAD" || !BRANCH.test(branch)) return { available: false, reason: "no branch checked out (detached HEAD)" };

  let prs: unknown;
  try {
    prs = json(await deps.gh(["pr", "list", "--repo", repo, "--head", branch, "--state", "all", "--limit", "1", "--json", "number,title,state,url,isDraft,reviewDecision,mergeStateStatus,statusCheckRollup"]));
  } catch (e) {
    return { available: false, reason: ghReason(e) };
  }
  const first = Array.isArray(prs) ? (prs[0] as Record<string, unknown> | undefined) : undefined;
  if (first && typeof first.number === "number") {
    const { checks, state } = summarizeChecks(first.statusCheckRollup);
    const pr: CiPr = {
      number: first.number, title: str(first.title, 200), state: str(first.state, 20), url: httpUrl(first.url) ?? "", isDraft: first.isDraft === true,
      review: str(first.reviewDecision, 30) || null, mergeState: str(first.mergeStateStatus, 30) || null,
    };
    return { available: true, repo, branch, pr, checks, checksState: state, runs: [] };
  }

  // No PR: show the latest workflow runs for the branch instead.
  let runsRaw: unknown;
  try {
    runsRaw = json(await deps.gh(["run", "list", "--repo", repo, "--branch", branch, "--limit", "5", "--json", "name,status,conclusion,url,createdAt,headBranch"]));
  } catch {
    runsRaw = [];
  }
  const runs: CiRun[] = [];
  for (const r of Array.isArray(runsRaw) ? runsRaw.slice(0, 5) : []) {
    const o = r as Record<string, unknown>;
    if (typeof o?.name !== "string") continue;
    runs.push({ name: str(o.name, 120), state: checkState(o.status, o.conclusion), branch: str(o.headBranch, 120), ...(httpUrl(o.url) ? { url: httpUrl(o.url) } : {}), ...(typeof o.createdAt === "string" ? { createdAt: o.createdAt.slice(0, 30) } : {}) });
  }
  const live = runs.filter((r) => r.state !== "skipped");
  const checksState: CiState = !live.length ? "none" : live.some((r) => r.state === "failing") ? "failing" : live.some((r) => r.state === "pending") ? "pending" : "passing";
  return { available: true, repo, branch, pr: null, checks: [], checksState, runs };
}

// gh's own error text can include paths/hosts; map to a few fixed reasons.
function ghReason(e: unknown): string {
  const m = String((e as { stderr?: string; message?: string })?.stderr ?? (e as Error)?.message ?? "");
  if (/ENOENT/.test(m)) return "the GitHub CLI (gh) is not installed on the server";
  if (/auth|login|token|credential|401|403/i.test(m)) return "the server is not signed in to GitHub (gh auth login)";
  if (/Could not resolve|404|not found/i.test(m)) return "that repository was not found on GitHub";
  return "could not reach GitHub";
}

const realDeps: CiDeps = {
  git: async (cwd, argv) => (await gitRun(cwd, argv)).stdout,
  gh: async (argv) => {
    const env = gitEnv();
    env.GH_PROMPT_DISABLED = "1";
    env.NO_COLOR = "1";
    env.GH_NO_UPDATE_NOTIFIER = "1";
    delete env.GH_BROWSER;
    return (await exec("gh", argv, { env, timeout: 15_000, maxBuffer: 1024 * 1024 })).stdout;
  },
};

let override: CiDeps | null = null;
/** Tests only. */
export function _setCiDepsForTest(d: CiDeps | null): void {
  override = d;
}

const cache = new Map<string, { at: number; value: CiResult }>();
const TTL_MS = 30_000;
export const _clearCiCache = (): void => cache.clear();

export function registerCiRoutes(app: FastifyInstance, db: DB): void {
  const limit = { config: { rateLimit: { max: 30, timeWindow: "1 minute" } } };
  const run = async (cwd: string | undefined, reply: { code: (n: number) => { send: (b: unknown) => unknown } }) => {
    if (!cwd) return reply.code(404).send({ error: "not found" });
    if (!pathInRoots(cwd)) return reply.code(403).send({ error: "path out of bounds" });
    const hit = cache.get(cwd);
    if (hit && Date.now() - hit.at < TTL_MS) return hit.value;
    const value = await fetchCi(cwd, override ?? realDeps);
    cache.set(cwd, { at: Date.now(), value });
    return value;
  };
  app.get("/projects/:id/ci", limit, async (req, reply) => {
    const row = db.prepare("SELECT path FROM projects WHERE id = ?").get((req.params as { id: string }).id) as { path: string } | undefined;
    return run(row?.path, reply);
  });
  app.get("/sessions/:id/ci", limit, async (req, reply) => {
    const row = db
      .prepare("SELECT COALESCE(s.worktree_path, p.path) AS path FROM sessions s JOIN projects p ON p.id = s.project_id WHERE s.id = ?")
      .get((req.params as { id: string }).id) as { path: string } | undefined;
    return run(row?.path, reply);
  });
}
