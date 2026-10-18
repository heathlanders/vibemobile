// Swarm tasks + file leases (proposal 65). Pure DB logic: scope handling, the
// atomic claim, completion and the lease lookup. No Fastify and no session code,
// so peer-tools.ts and claude.ts can import it without a cycle (routes are in
// task-routes.ts).
//
// A lease is not a record of its own: it is the scope of a task in running|review,
// held by that task's session. It lifts when the task is done or back to ready.
// Leases are advisory coordination, not a security boundary (security.md #35).

import { realpathSync } from "node:fs";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import type { DB } from "./db.js";
import { logEvent } from "./auth.js";
import { notifyDevices } from "./push.js";
import { gitRun } from "./git-run.js";

export const MAX_SCOPE_ENTRIES = 50;
export const MAX_SCOPE_CHARS = 512;
export const MAX_TITLE_CHARS = 200;
export const MAX_BODY_CHARS = 20_000;
export const MAX_DEPS = 50;
export const TASK_STATES = ["ready", "running", "review", "done"] as const;
export type TaskState = (typeof TASK_STATES)[number];

export const swarmMax = (): number => Number(process.env.VIBE_SWARM_MAX ?? 3);

export type TaskRow = {
  id: string;
  project_id: string;
  title: string;
  body: string;
  scope: string[];
  deps: string[];
  state: TaskState;
  session_id: string | null;
  created_at: string;
  updated_at: string;
};

export const COLS = "id, project_id, title, body, scope, deps, state, session_id, created_at, updated_at";

export function toTask(r: any): TaskRow {
  return { ...r, scope: JSON.parse(r.scope), deps: JSON.parse(r.deps) };
}

export const getTask = (db: DB, id: string): TaskRow | null => {
  const r = db.prepare(`SELECT ${COLS} FROM tasks WHERE id = ?`).get(id);
  return r ? toTask(r) : null;
};

const segs = (p: string): string[] => p.split("/").filter(Boolean);

// Normalise a scope list: repo-relative prefixes, no `..`, no leading `/`, no `.git`.
// Returns the cleaned, de-duplicated list, or an error message.
export function normalizeScope(raw: unknown): string[] | { error: string } {
  if (!Array.isArray(raw)) return { error: "scope must be an array of paths" };
  if (raw.length > MAX_SCOPE_ENTRIES) return { error: `scope has too many entries (max ${MAX_SCOPE_ENTRIES})` };
  const out: string[] = [];
  for (const e of raw) {
    if (typeof e !== "string") return { error: "scope entries must be strings" };
    if (e.length > MAX_SCOPE_CHARS) return { error: `scope entry too long (max ${MAX_SCOPE_CHARS} chars)` };
    const t = e.trim();
    if (!t) continue; // blank lines from the form
    if (t.includes("\0") || t.includes("\\")) return { error: `invalid scope path: ${t}` };
    if (t.startsWith("/")) return { error: `scope path must be relative: ${t}` };
    const parts = segs(t).filter((s) => s !== ".");
    if (!parts.length) return { error: `invalid scope path: ${t}` };
    if (parts.some((s) => s === ".." || s.toLowerCase() === ".git")) return { error: `scope path not allowed: ${t}` };
    const clean = parts.join("/");
    if (!out.includes(clean)) out.push(clean);
  }
  return out;
}

// One entry equals the other or is a directory prefix of it, compared per path segment.
export function entriesOverlap(a: string, b: string): boolean {
  const x = segs(a);
  const y = segs(b);
  const n = Math.min(x.length, y.length);
  for (let i = 0; i < n; i++) if (x[i] !== y[i]) return false;
  return true;
}

export const scopesOverlap = (a: string[], b: string[]): boolean => a.some((x) => b.some((y) => entriesOverlap(x, y)));

const sessionOf = (db: DB, id: string) =>
  db.prepare("SELECT project_id, kind, worktree_path FROM sessions WHERE id = ?").get(id) as
    | { project_id: string; kind: string; worktree_path: string | null }
    | undefined;

type Reserved = { ok: true; task: TaskRow } | { ok: false; error: string };

// Atomically move a ready task to running. `sessionId` null = reserve for a dispatch
// that is still creating its session (bound by bindSession afterwards). Checks, in order:
// ready, deps done, no overlapping running|review task, VIBE_SWARM_MAX. better-sqlite3
// transactions are synchronous, so two callers cannot interleave; the UPDATE's
// `WHERE state='ready'` is the second guard.
export function reserveTask(db: DB, taskId: string, sessionId: string | null): Reserved {
  return db.transaction((): Reserved => {
    const t = getTask(db, taskId);
    if (!t) return { ok: false, error: "no such task" };
    if (t.state !== "ready") return { ok: false, error: `task is ${t.state}, not ready` };
    for (const d of t.deps) {
      const dep = getTask(db, d);
      if (dep && dep.state !== "done") return { ok: false, error: `blocked by dependency '${dep.title}' (${dep.id}), which is ${dep.state}` };
    }
    const held = db
      .prepare(`SELECT ${COLS} FROM tasks WHERE project_id = ? AND state IN ('running','review') AND id != ?`)
      .all(t.project_id, t.id)
      .map(toTask);
    const clash = held.find((h) => scopesOverlap(h.scope, t.scope));
    if (clash) return { ok: false, error: `scope overlaps task '${clash.title}' (${clash.id}), which is ${clash.state}` };
    const running = held.filter((h) => h.state === "running");
    if (running.length >= swarmMax()) {
      return { ok: false, error: `swarm limit reached (${swarmMax()} running tasks): finish '${running[0].title}' (${running[0].id}) first` };
    }
    const r = db
      .prepare("UPDATE tasks SET state='running', session_id=?, updated_at=? WHERE id=? AND state='ready'")
      .run(sessionId, new Date().toISOString(), t.id);
    if (r.changes !== 1) return { ok: false, error: "task is no longer ready" };
    return { ok: true, task: { ...t, state: "running", session_id: sessionId } };
  })();
}

export const bindSession = (db: DB, taskId: string, sessionId: string): void => {
  db.prepare("UPDATE tasks SET session_id=?, updated_at=? WHERE id=?").run(sessionId, new Date().toISOString(), taskId);
};

export const releaseTask = (db: DB, taskId: string): void => {
  db.prepare("UPDATE tasks SET state='ready', session_id=NULL, updated_at=? WHERE id=?").run(new Date().toISOString(), taskId);
};

type Result = { ok: true; text: string } | { ok: false; error: string };

// Peer tool: bind a ready task to the calling session.
export function claimTask(db: DB, selfId: string, taskId: string): Result {
  const me = sessionOf(db, selfId);
  if (!me) return { ok: false, error: "this session isn't registered" };
  if (!me.worktree_path) return { ok: false, error: "claim_task needs a worktree session — start the session with worktree on" };
  const t = getTask(db, taskId);
  // Unknown and other-project look identical.
  if (!t || t.project_id !== me.project_id) return { ok: false, error: "no such task in this project" };
  const r = reserveTask(db, taskId, selfId);
  if (!r.ok) return { ok: false, error: r.error };
  logEvent(db, "task.claim", null, `${selfId}:${taskId}`);
  return { ok: true, text: `Claimed '${r.task.title}'. Stay within its scope (${r.task.scope.join(", ") || "none"}) and call complete_task when done.` };
}

// Peer tool: only the owning session moves its task to review.
export function completeTask(db: DB, selfId: string, taskId: string, summary: string): Result {
  const t = getTask(db, taskId);
  const me = sessionOf(db, selfId);
  if (!t || !me || t.project_id !== me.project_id) return { ok: false, error: "no such task in this project" };
  if (t.session_id !== selfId) return { ok: false, error: "only the session that owns this task can complete it" };
  if (t.state !== "running") return { ok: false, error: `task is ${t.state}, not running` };
  const text = summary.trim();
  const body = text ? `${t.body}${t.body ? "\n\n" : ""}## Result\n${text.slice(0, MAX_BODY_CHARS)}` : t.body;
  const r = db
    .prepare("UPDATE tasks SET state='review', body=?, updated_at=? WHERE id=? AND state='running' AND session_id=?")
    .run(body, new Date().toISOString(), t.id, selfId);
  if (r.changes !== 1) return { ok: false, error: "task is no longer running" };
  logEvent(db, "task.complete", null, `${selfId}:${taskId}`);
  notifyDevices(db, "task_review", selfId);
  return { ok: true, text: `'${t.title}' is now in review. The user will merge it and mark it done.` };
}

export function listTasksText(db: DB, selfId: string): Result {
  const me = sessionOf(db, selfId);
  if (!me) return { ok: false, error: "this session isn't registered" };
  const tasks = db.prepare(`SELECT ${COLS} FROM tasks WHERE project_id = ? ORDER BY created_at`).all(me.project_id).map(toTask);
  if (!tasks.length) return { ok: true, text: "No tasks in this project." };
  const byId = new Map(tasks.map((t) => [t.id, t]));
  const held = tasks.filter((t) => t.state === "running" || t.state === "review");
  return {
    ok: true,
    text: tasks
      .map((t) => {
        const depsDone = t.deps.every((d) => !byId.has(d) || byId.get(d)!.state === "done");
        const free = !held.some((h) => h.id !== t.id && scopesOverlap(h.scope, t.scope));
        const ready = t.state === "ready" && depsDone && free;
        return (
          `- ${t.id} [${t.state}]${ready ? " READY" : ""} ${t.title}` +
          `\n    scope: ${t.scope.join(", ") || "(none)"}` +
          (t.deps.length ? `\n    deps: ${t.deps.join(", ")}` : "") +
          (t.session_id ? `\n    session: ${t.session_id}` : "")
        );
      })
      .join("\n"),
  };
}

// Change broadcast (proposal 64, S4). When a task is marked done (the user merged it),
// every other live Claude session in the project gets a turn listing the files it
// changed. Sent by the daemon, not a peer, so the per-sender rate limit doesn't apply.
// Changed files come from the task branch since its base; if the branch is gone, the
// task's scope stands in.
const MAX_BROADCAST_FILES = 50;

export async function broadcastTaskDone(
  db: DB,
  registry: Map<string, { pushUser(text: string): void }>,
  t: TaskRow,
): Promise<void> {
  const others = (
    db
      .prepare("SELECT id FROM sessions WHERE project_id = ? AND kind = 'claude' AND id IS NOT ?")
      .all(t.project_id, t.session_id) as { id: string }[]
  ).filter((r) => registry.has(r.id));
  if (!others.length) return;
  const wt = t.session_id
    ? (db
        .prepare("SELECT s.worktree_branch, s.base_ref, p.path FROM sessions s JOIN projects p ON p.id = s.project_id WHERE s.id = ?")
        .get(t.session_id) as { worktree_branch: string | null; base_ref: string | null; path: string } | undefined)
    : undefined;
  let files = t.scope;
  if (wt?.worktree_branch && wt.base_ref) {
    try {
      const out = await gitRun(wt.path, ["diff", "--name-only", `${wt.base_ref}...${wt.worktree_branch}`, "--"]);
      files = out.stdout.split("\n").filter(Boolean);
    } catch {
      // branch deleted or repo refused (git-run.ts): fall back to the scope
    }
  }
  const list = files.slice(0, MAX_BROADCAST_FILES).map((f) => `- ${f}`);
  if (files.length > MAX_BROADCAST_FILES) list.push(`- … and ${files.length - MAX_BROADCAST_FILES} more`);
  const text = [
    `[Notice from VibeMobile — not typed by the user. Another session's task '${t.title}' (${t.id}) was merged.]`,
    `\nFiles it changed:\n${list.join("\n") || "- (none recorded)"}`,
    "\nIf your work touches these files, rebase onto the updated branch (or pull, in the main checkout) before continuing. Otherwise carry on.",
  ].join("\n");
  for (const o of others) registry.get(o.id)?.pushUser(text);
  logEvent(db, "task.broadcast", null, `${t.id}->${others.length}`);
}

export function taskPrompt(t: TaskRow): string {
  return [
    `You have been assigned a task in this project: ${t.title}`,
    t.body ? `\n${t.body}` : "",
    `\nScope (the files and directories you may change; other sessions hold the rest): ${t.scope.join(", ") || "(no exclusive files)"}`,
    "\nWork only within that scope. When you are done, call the complete_task tool with this task's id " +
      `(${t.id}) and a short summary of what you did.`,
  ].join("\n");
}

// ---- leases ----------------------------------------------------------------

const canonical = (p: string): string => {
  const abs = resolve(p);
  try {
    return realpathSync(abs);
  } catch {
    const parent = dirname(abs);
    return parent === abs ? abs : join(canonical(parent), basename(abs));
  }
};

const LEASED_TOOLS: Record<string, string> = {
  Write: "file_path",
  Edit: "file_path",
  MultiEdit: "file_path",
  NotebookEdit: "notebook_path",
};

// Repo-relative path of a tool call's target within `root`, or null when the tool is
// not a leased write tool or the path lies outside the checkout.
export function leasedToolPath(toolName: string, input: Record<string, unknown>, root: string): string | null {
  const key = LEASED_TOOLS[toolName];
  const raw = key ? input[key] : undefined;
  if (typeof raw !== "string" || !raw) return null;
  const rel = relative(canonical(root), canonical(resolve(root, raw)));
  if (!rel || rel === ".." || rel.startsWith(".." + sep) || isAbsolute(rel)) return null;
  return rel.split(sep).join("/");
}

// The task (running|review, held by another session in the same project) whose scope
// covers `relPath`, or null. The holder is never blocked.
export function leaseBlocker(db: DB, selfId: string, relPath: string): { title: string; session_id: string | null } | null {
  const me = sessionOf(db, selfId);
  if (!me) return null;
  const rows = db
    .prepare(
      `SELECT title, scope, session_id FROM tasks
       WHERE project_id = ? AND state IN ('running','review') AND (session_id IS NULL OR session_id != ?)`,
    )
    .all(me.project_id, selfId) as { title: string; scope: string; session_id: string | null }[];
  for (const r of rows) {
    if ((JSON.parse(r.scope) as string[]).some((e) => entriesOverlap(e, relPath))) return { title: r.title, session_id: r.session_id };
  }
  return null;
}
