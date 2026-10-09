// Worktree-per-session (ADR 0022). A Claude session can run in its own git
// worktree so parallel sessions don't trample one checkout.
//
// All git goes through gitRun (ADR 0024): fixed argv, repo-planted hooks/config
// neutralised. Nothing here takes text from the client — the path and branch are
// derived from the server-minted session id, which is checked against its exact
// shape before use.

import { appendFileSync, existsSync, mkdirSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { gitRun } from "./git-run.js";
import { canonical, inside } from "./file-scope.js";

export const WORKTREE_DIR = ".vibe-worktrees";
const SESSION_ID = /^s_[0-9a-f]{12}$/; // sessions.ts newId()
const SLOW_MS = 60_000; // checkout of a big repo; the 5 s default is for status

export type Worktree = { path: string; branch: string; baseRef: string };
export class WorktreeError extends Error {}

export const worktreePathFor = (projectPath: string, sessionId: string): string =>
  join(projectPath, WORKTREE_DIR, sessionId);
export const branchFor = (sessionId: string): string => `vibe/${sessionId}`;

function assertSessionId(sessionId: string): void {
  if (!SESSION_ID.test(sessionId)) throw new WorktreeError("bad session id");
}

// Keep `.vibe-worktrees/` out of the project's `git status` without touching any
// tracked file (info/exclude is local to this clone).
function excludeWorktreeDir(projectPath: string, excludeFile: string): void {
  const file = resolve(projectPath, excludeFile);
  const line = `${WORKTREE_DIR}/`;
  const cur = existsSync(file) ? readFileSync(file, "utf8") : "";
  if (cur.split("\n").includes(line)) return;
  mkdirSync(dirname(file), { recursive: true });
  appendFileSync(file, `${cur && !cur.endsWith("\n") ? "\n" : ""}${line}\n`);
}

export async function createWorktree(projectPath: string, sessionId: string): Promise<Worktree> {
  assertSessionId(sessionId);
  const path = worktreePathFor(projectPath, sessionId);
  // Defence in depth: the result must sit strictly inside the project.
  if (!inside(canonical(path), canonical(projectPath))) throw new WorktreeError("worktree path escapes project");

  let baseRef: string;
  try {
    const bare = (await gitRun(projectPath, ["rev-parse", "--is-bare-repository"])).stdout.trim();
    if (bare !== "false") throw new WorktreeError("project is a bare repository");
    baseRef = (await gitRun(projectPath, ["rev-parse", "--verify", "HEAD"])).stdout.trim();
  } catch (e) {
    if (e instanceof WorktreeError) throw e;
    throw new WorktreeError("project is not a git repository with at least one commit");
  }

  const branch = branchFor(sessionId);
  try {
    const { stdout } = await gitRun(projectPath, ["rev-parse", "--git-path", "info/exclude"]);
    excludeWorktreeDir(projectPath, stdout.trim());
    await gitRun(projectPath, ["worktree", "add", "--no-track", "-b", branch, "--", path, "HEAD"], { timeout: SLOW_MS });
  } catch {
    throw new WorktreeError("could not create the worktree");
  }
  return { path, branch, baseRef };
}

export type RemoveResult = { kept: false } | { kept: true; reason: "dirty" | "commits" | "error" };

// Remove only when nothing would be lost: clean tree and no commits beyond the
// base. Never --force. A directory someone already deleted by hand is just pruned.
export async function removeWorktree(
  projectPath: string,
  wt: { path: string; branch: string; baseRef: string },
): Promise<RemoveResult> {
  // Without a real base commit and branch we cannot prove nothing is lost: an empty
  // baseRef would make `..branch` mean `HEAD..branch` and read as "no new commits".
  if (!/^[0-9a-f]{40}$/.test(wt.baseRef) || !wt.branch.startsWith("vibe/")) return { kept: true, reason: "error" };
  try {
    if (!existsSync(wt.path)) {
      await gitRun(projectPath, ["worktree", "prune"]);
      return { kept: false };
    }
    const dirty = (await gitRun(wt.path, ["status", "--porcelain"])).stdout.trim().length > 0;
    if (dirty) return { kept: true, reason: "dirty" };
    const ahead = Number((await gitRun(projectPath, ["rev-list", "--count", `${wt.baseRef}..${wt.branch}`])).stdout.trim());
    if (!(ahead === 0)) return { kept: true, reason: "commits" };
    await gitRun(projectPath, ["worktree", "remove", "--", wt.path], { timeout: SLOW_MS });
    await gitRun(projectPath, ["branch", "-d", "--", wt.branch]).catch(() => {}); // merged-only; harmless if not
    return { kept: false };
  } catch {
    return { kept: true, reason: "error" };
  }
}
