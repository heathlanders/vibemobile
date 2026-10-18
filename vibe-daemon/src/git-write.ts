// Git write surface: stage, commit, branch — NO push (ADR 0024, security.md #15/#26).
// Kept apart from git.ts so that file's read-only guarantee stays literally true.
//
// Every call goes through gitRun (hooks/config planted by the agent are neutralised).
// Client text reaches git in exactly two ways: pathspecs AFTER `--` (made literal by
// --literal-pathspecs, so no glob/magic), and the commit message as the VALUE of `-m`.
// Branch names are allowlisted and re-validated by `git check-ref-format`.
//
// Routes exist in two scopes:
//   /projects/:id/git/...  — the project checkout
//   /sessions/:id/git/...  — the session's checkout (its worktree, ADR 0022, if any);
//                            a stage with no `paths` defaults to the session's edit set

import { lstatSync } from "node:fs";
import { basename, isAbsolute, relative, resolve, sep } from "node:path";
import type { FastifyInstance, FastifyReply } from "fastify";
import type { DB } from "./db.js";
import { logEvent, type Device } from "./auth.js";
import { canonical, inside } from "./file-scope.js";
import { collectFileEdits } from "./file-edits.js";
import { gitRun, UnsafeGitConfigError } from "./git-run.js";
import { pathInRoots } from "./paths.js";

const SLOW_MS = 30_000;
const MAX_PATHS = 500;
const MAX_PATH_LEN = 4096;
const MAX_MESSAGE = 500;
const BRANCH_RE = /^[A-Za-z0-9][A-Za-z0-9._/-]{0,63}$/;

// Files that commonly hold secrets. Refused unless the caller opts in with
// allowSensitive — a just-written .env must not be swept into a commit by accident.
const SENSITIVE: RegExp[] = [
  /^\.env(\..*)?$/i,
  /\.(pem|key|p12|pfx)$/i,
  /^id_(rsa|dsa|ecdsa|ed25519)(\.pub)?$/i,
  /^\.netrc$/i,
];

export const isSensitivePath = (rel: string): boolean => SENSITIVE.some((re) => re.test(basename(rel)));
export const isGitInternal = (rel: string): boolean => rel.split(/[\\/]/).includes(".git");

export function validBranchName(name: unknown): name is string {
  return (
    typeof name === "string" &&
    BRANCH_RE.test(name) &&
    !name.includes("..") &&
    !name.includes("@{") &&
    !name.endsWith("/") &&
    !name.endsWith(".lock") &&
    !name.includes("//")
  );
}

export function validCommitMessage(m: unknown): m is string {
  return (
    typeof m === "string" &&
    m.trim().length > 0 &&
    m.length <= MAX_MESSAGE &&
    !m.includes("\0") &&
    !m.trimStart().startsWith("-")
  );
}

type PathCheck = { ok: true; rel: string } | { ok: false; why: string };

// One client path -> a safe repo-relative path, or the reason it was refused.
export function checkStagePath(cwd: string, raw: unknown, allowSensitive: boolean): PathCheck {
  if (typeof raw !== "string" || !raw || raw.length > MAX_PATH_LEN || raw.includes("\0")) return { ok: false, why: "bad path" };
  if (raw.startsWith("-")) return { ok: false, why: "bad path" };
  const abs = isAbsolute(raw) ? raw : resolve(cwd, raw);
  const root = canonical(cwd);
  if (!inside(canonical(abs), root)) return { ok: false, why: "outside the project" };
  const rel = relative(resolve(cwd), resolve(abs));
  if (!rel || rel.startsWith("..")) return { ok: false, why: "outside the project" };
  if (isGitInternal(rel)) return { ok: false, why: "inside .git" };
  try {
    if (lstatSync(abs).isDirectory()) return { ok: false, why: "name files, not directories" };
  } catch {
    /* a deleted file is a legitimate thing to stage */
  }
  if (!allowSensitive && isSensitivePath(rel)) return { ok: false, why: `looks like a secret (${basename(rel)})` };
  return { ok: true, rel: rel.split(sep).join("/") };
}

// A person-readable author from the paired device name; never trusted raw.
const authorName = (name: string | undefined): string =>
  (name ?? "").replace(/[\u0000-\u001f<>]/g, "").trim().slice(0, 64) || "vibe";

// One git write at a time per checkout.
const locks = new Map<string, Promise<unknown>>();
function serial<T>(key: string, fn: () => Promise<T>): Promise<T> {
  const run = (locks.get(key) ?? Promise.resolve()).catch(() => {}).then(fn);
  locks.set(key, run);
  void run.finally(() => locks.get(key) === run && locks.delete(key)).catch(() => {});
  return run;
}

const refused = (reply: FastifyReply, code: number, error: string) => reply.code(code).send({ error });
// A repo refused by gitRun's driver check says why (ADR 0032 §4); other failures stay generic.
const why = (e: unknown, fallback: string) => (e instanceof UnsafeGitConfigError ? e.message : fallback);

type Ctx = { cwd: string; sessionId?: string };

export function registerGitWriteRoutes(app: FastifyInstance, db: DB): void {
  const limit = { config: { rateLimit: { max: 30, timeWindow: "1 minute" } } };
  const deviceOf = (req: unknown) => (req as { device?: Device }).device;

  // ---- the three operations, scope-independent --------------------------------

  async function stage(ctx: Ctx, body: { paths?: unknown; allowSensitive?: unknown }, reply: FastifyReply, deviceId: string | null) {
    const allowSensitive = body.allowSensitive === true;
    let rels: string[] | null = null; // null = `add -u` (tracked changes only)
    if (body.paths !== undefined) {
      if (!Array.isArray(body.paths) || body.paths.length === 0 || body.paths.length > MAX_PATHS) {
        return refused(reply, 400, `paths must be 1-${MAX_PATHS} strings`);
      }
      rels = [];
      for (const p of body.paths) {
        const c = checkStagePath(ctx.cwd, p, allowSensitive);
        if (!c.ok) return refused(reply, 400, `${typeof p === "string" ? p.slice(0, 120) : "path"}: ${c.why}`);
        rels.push(c.rel);
      }
    } else if (ctx.sessionId) {
      // The session's own edit set, skipping anything outside this checkout and anything sensitive.
      rels = [];
      for (const abs of collectFileEdits(db, ctx.sessionId).keys()) {
        const c = checkStagePath(ctx.cwd, abs, allowSensitive);
        if (c.ok) rels.push(c.rel);
      }
      if (rels.length === 0) return refused(reply, 409, "nothing to stage from this session's edits");
    }
    try {
      // `add -u` checks submodules for changes, which runs their filters under their
      // own config — config gitRun can't see (ADR 0032 §4). Explicit paths don't.
      if (!rels && /^160000 /m.test((await gitRun(ctx.cwd, ["ls-files", "-s"], { maxBuffer: 64 * 1024 * 1024 })).stdout)) {
        return refused(reply, 409, "this repo has submodules: stage specific paths instead");
      }
      const argv = rels ? ["--literal-pathspecs", "add", "--", ...rels] : ["add", "-u"];
      await serial(ctx.cwd, () => gitRun(ctx.cwd, argv, { timeout: SLOW_MS }));
      const staged = (await gitRun(ctx.cwd, ["diff", "--cached", "--name-only"])).stdout.split("\n").filter(Boolean);
      logEvent(db, "git.stage", deviceId, `${ctx.sessionId ?? ctx.cwd}:${staged.length}`);
      return { staged };
    } catch (e) {
      return refused(reply, 409, why(e, "git refused to stage those paths"));
    }
  }

  async function commit(ctx: Ctx, body: { message?: unknown }, reply: FastifyReply, device: Device | undefined) {
    if (!validCommitMessage(body.message)) {
      return refused(reply, 400, `message required: 1-${MAX_MESSAGE} chars, no NUL, must not start with "-"`);
    }
    const message = body.message;
    try {
      return await serial(ctx.cwd, async () => {
        const has = (await gitRun(ctx.cwd, ["diff", "--cached", "--name-only"])).stdout.trim();
        if (!has) return refused(reply, 409, "nothing staged");
        await gitRun(
          ctx.cwd,
          [
            "-c", `user.name=${authorName(device?.name)}`,
            "-c", `user.email=${device?.id ?? "unknown"}@vibe.local`,
            "-c", "commit.gpgsign=false",
            "commit", "--no-verify", "--no-gpg-sign", "-m", message,
          ],
          { timeout: SLOW_MS },
        );
        const sha = (await gitRun(ctx.cwd, ["rev-parse", "HEAD"])).stdout.trim();
        const files = (await gitRun(ctx.cwd, ["diff-tree", "--root", "--no-commit-id", "--name-only", "-r", "HEAD"])).stdout
          .split("\n")
          .filter(Boolean).length;
        logEvent(db, "git.commit", device?.id ?? null, `${ctx.sessionId ?? ctx.cwd}:${sha.slice(0, 12)}:${files}:${message.slice(0, 80)}`);
        return { sha, subject: message.split("\n")[0].slice(0, 200), filesChanged: files };
      });
    } catch (e) {
      return refused(reply, 409, why(e, "git refused to commit"));
    }
  }

  async function branch(ctx: Ctx, body: { name?: unknown }, reply: FastifyReply, deviceId: string | null) {
    if (!validBranchName(body.name)) return refused(reply, 400, "invalid branch name");
    const name = body.name;
    try {
      return await serial(ctx.cwd, async () => {
        await gitRun(ctx.cwd, ["check-ref-format", "--branch", name]);
        // Tracked changes only: untracked files (build output, scratch) can't conflict
        // with a new branch at the same commit, so they shouldn't block it.
        if ((await gitRun(ctx.cwd, ["status", "--porcelain", "--untracked-files=no", "--ignore-submodules=all"])).stdout.trim()) {
          return refused(reply, 409, "working tree has uncommitted changes — commit or discard them first");
        }
        await gitRun(ctx.cwd, ["checkout", "-b", name], { timeout: SLOW_MS });
        logEvent(db, "git.branch", deviceId, `${ctx.sessionId ?? ctx.cwd}:${name}`);
        return { branch: name };
      });
    } catch (e) {
      return refused(reply, 409, why(e, "could not create that branch (it may already exist)"));
    }
  }

  // ---- scope resolution ---------------------------------------------------------

  const projectCtx = (id: string, reply: FastifyReply): Ctx | null => {
    const row = db.prepare("SELECT path FROM projects WHERE id = ?").get(id) as { path: string } | undefined;
    if (!row) {
      refused(reply, 404, "not found");
      return null;
    }
    if (!pathInRoots(row.path)) {
      refused(reply, 403, "path out of bounds");
      return null;
    }
    return { cwd: row.path };
  };
  const sessionCtx = (id: string, reply: FastifyReply): Ctx | null => {
    const row = db
      .prepare(
        "SELECT COALESCE(s.worktree_path, p.path) AS cwd FROM sessions s JOIN projects p ON p.id = s.project_id WHERE s.id = ? AND s.kind = 'claude'",
      )
      .get(id) as { cwd: string } | undefined;
    if (!row) {
      refused(reply, 404, "not found");
      return null;
    }
    if (!pathInRoots(row.cwd)) {
      refused(reply, 403, "path out of bounds");
      return null;
    }
    return { cwd: row.cwd, sessionId: id };
  };

  for (const [prefix, resolveCtx] of [
    ["/projects", projectCtx],
    ["/sessions", sessionCtx],
  ] as const) {
    app.post(`${prefix}/:id/git/stage`, limit, async (req, reply) => {
      const ctx = resolveCtx((req.params as { id: string }).id, reply);
      return ctx ? stage(ctx, (req.body ?? {}) as object, reply, deviceOf(req)?.id ?? null) : reply;
    });
    app.post(`${prefix}/:id/git/commit`, limit, async (req, reply) => {
      const ctx = resolveCtx((req.params as { id: string }).id, reply);
      return ctx ? commit(ctx, (req.body ?? {}) as object, reply, deviceOf(req)) : reply;
    });
    app.post(`${prefix}/:id/git/branch`, limit, async (req, reply) => {
      const ctx = resolveCtx((req.params as { id: string }).id, reply);
      return ctx ? branch(ctx, (req.body ?? {}) as object, reply, deviceOf(req)?.id ?? null) : reply;
    });
  }
}
