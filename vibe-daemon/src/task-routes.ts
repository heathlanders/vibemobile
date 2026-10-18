// Swarm task REST (proposal 65), shaped like notes.ts. Dispatch creates a worktree
// Claude session through the same createSession() POST /sessions uses, then starts
// its first turn itself (no WS attach needed) via the injected `start`.

import { randomUUID } from "node:crypto";
import type { FastifyInstance } from "fastify";
import type { DB } from "./db.js";
import type { Tmux } from "./tmux.js";
import { logEvent, type Device } from "./auth.js";
import { createSession } from "./sessions.js";
import { taskInQueue } from "./merge-queue.js";
import {
  COLS, MAX_BODY_CHARS, MAX_DEPS, MAX_TITLE_CHARS, bindSession, broadcastTaskDone, getTask, normalizeScope, releaseTask,
  reserveTask, taskPrompt, toTask,
} from "./tasks.js";

const nowIso = () => new Date().toISOString();

type Body = { title?: unknown; body?: unknown; scope?: unknown; deps?: unknown; state?: unknown };

export function registerTaskRoutes(
  app: FastifyInstance,
  db: DB,
  tmux: Tmux,
  deps: { start: (row: Record<string, unknown>) => void; registry: Map<string, { pushUser(text: string): void }> },
): void {
  const device = (req: unknown) => (req as { device?: Device }).device?.id ?? null;

  const checkTitle = (v: unknown): string | { error: string } => {
    if (typeof v !== "string" || !v.trim()) return { error: "title required" };
    if (v.trim().length > MAX_TITLE_CHARS) return { error: "title too long" };
    return v.trim();
  };
  const checkBody = (v: unknown): string | { error: string } => {
    if (typeof v !== "string") return { error: "body must be a string" };
    if (v.length > MAX_BODY_CHARS) return { error: "body too long" };
    return v;
  };
  // Deps must be other tasks of the same project (and not the task itself).
  const checkDeps = (v: unknown, projectId: string, selfId?: string): string[] | { error: string } => {
    if (!Array.isArray(v) || v.some((d) => typeof d !== "string")) return { error: "deps must be an array of task ids" };
    if (v.length > MAX_DEPS) return { error: `too many deps (max ${MAX_DEPS})` };
    const out = [...new Set(v as string[])];
    for (const d of out) {
      if (d === selfId) return { error: "a task cannot depend on itself" };
      const row = db.prepare("SELECT project_id FROM tasks WHERE id = ?").get(d) as { project_id: string } | undefined;
      if (!row || row.project_id !== projectId) return { error: `unknown dependency: ${d}` };
    }
    return out;
  };
  const isErr = (v: unknown): v is { error: string } => typeof v === "object" && v !== null && !Array.isArray(v) && "error" in v;

  app.get("/projects/:id/tasks", async (req, reply) => {
    const { id } = req.params as { id: string };
    if (!db.prepare("SELECT 1 FROM projects WHERE id = ?").get(id)) return reply.code(404).send({ error: "project not found" });
    return db.prepare(`SELECT ${COLS} FROM tasks WHERE project_id = ? ORDER BY created_at ASC`).all(id).map(toTask);
  });

  app.post("/projects/:id/tasks", async (req, reply) => {
    const { id: projectId } = req.params as { id: string };
    if (!db.prepare("SELECT 1 FROM projects WHERE id = ?").get(projectId)) return reply.code(404).send({ error: "project not found" });
    const b = (req.body ?? {}) as Body;
    const title = checkTitle(b.title);
    if (isErr(title)) return reply.code(400).send(title);
    const text = checkBody(b.body ?? "");
    if (isErr(text)) return reply.code(400).send(text);
    const scope = normalizeScope(b.scope ?? []);
    if (isErr(scope)) return reply.code(400).send(scope);
    const depIds = checkDeps(b.deps ?? [], projectId);
    if (isErr(depIds)) return reply.code(400).send(depIds);
    const id = randomUUID();
    const ts = nowIso();
    db.prepare(`INSERT INTO tasks (${COLS}) VALUES (?,?,?,?,?,?,'ready',NULL,?,?)`).run(
      id, projectId, title, text, JSON.stringify(scope), JSON.stringify(depIds), ts, ts,
    );
    logEvent(db, "task.create", device(req), id);
    return reply.code(201).send(getTask(db, id));
  });

  // Fields only while ready; `state` may also be set: any → ready (releases the
  // lease), review → done.
  app.put("/tasks/:id", async (req, reply) => {
    const { id } = req.params as { id: string };
    const t = getTask(db, id);
    if (!t) return reply.code(404).send({ error: "not found" });
    const b = (req.body ?? {}) as Body;
    const editsFields = b.title !== undefined || b.body !== undefined || b.scope !== undefined || b.deps !== undefined;
    let { title, body, scope, deps: depIds } = t;
    if (editsFields) {
      if (t.state !== "ready" && !(b.state === "ready")) {
        return reply.code(409).send({ error: `task is ${t.state}: edit it only while ready` });
      }
      if (b.title !== undefined) {
        const v = checkTitle(b.title);
        if (isErr(v)) return reply.code(400).send(v);
        title = v;
      }
      if (b.body !== undefined) {
        const v = checkBody(b.body);
        if (isErr(v)) return reply.code(400).send(v);
        body = v;
      }
      if (b.scope !== undefined) {
        const v = normalizeScope(b.scope);
        if (isErr(v)) return reply.code(400).send(v);
        scope = v;
      }
      if (b.deps !== undefined) {
        const v = checkDeps(b.deps, t.project_id, t.id);
        if (isErr(v)) return reply.code(400).send(v);
        depIds = v;
      }
    }
    let state = t.state;
    let sessionId = t.session_id;
    if (b.state !== undefined && taskInQueue(db, id)) return reply.code(409).send({ error: "the task is in the merge queue: reject it there first" });
    if (b.state !== undefined) {
      if (b.state === "ready") {
        state = "ready";
        sessionId = null;
      } else if (b.state === "done") {
        if (t.state !== "review") return reply.code(409).send({ error: `only a task in review can be marked done (it is ${t.state})` });
        state = "done";
      } else {
        return reply.code(400).send({ error: "state may only be set to 'ready' or 'done'" });
      }
    }
    db.prepare("UPDATE tasks SET title=?, body=?, scope=?, deps=?, state=?, session_id=?, updated_at=? WHERE id=?").run(
      title, body, JSON.stringify(scope), JSON.stringify(depIds), state, sessionId, nowIso(), id,
    );
    logEvent(db, "task.update", device(req), b.state !== undefined ? `${id}:${state}` : id);
    const updated = getTask(db, id)!;
    if (t.state === "review" && state === "done") void broadcastTaskDone(db, deps.registry, updated).catch(() => {});
    return updated;
  });

  app.delete("/tasks/:id", async (req, reply) => {
    const { id } = req.params as { id: string };
    if (taskInQueue(db, id)) return reply.code(409).send({ error: "the task is in the merge queue: reject it there first" });
    db.prepare("DELETE FROM tasks WHERE id = ?").run(id);
    logEvent(db, "task.delete", device(req), id);
    return reply.code(204).send(); // idempotent
  });

  app.post("/tasks/:id/dispatch", async (req, reply) => {
    const { id } = req.params as { id: string };
    if (!getTask(db, id)) return reply.code(404).send({ error: "not found" });
    // Reserve first (checks + state flip in one transaction) so two dispatches can't both pass.
    const r = reserveTask(db, id, null);
    if (!r.ok) return reply.code(409).send({ error: r.error });
    const res = await createSession(
      db,
      tmux,
      { project_id: r.task.project_id, kind: "claude", title: r.task.title, initialPrompt: taskPrompt(r.task), worktree: true },
      device(req),
    ).catch((e: unknown) => ({ ok: false as const, status: 500, error: e instanceof Error ? e.message : "could not create the session" }));
    if (!res.ok) {
      releaseTask(db, id);
      return reply.code(res.status).send({ error: res.error });
    }
    bindSession(db, id, res.body.id);
    logEvent(db, "task.dispatch", device(req), `${id}:${res.body.id}`);
    // First turn without a client attached: the same start path a WS attach uses.
    deps.start(db.prepare("SELECT * FROM sessions WHERE id = ?").get(res.body.id) as Record<string, unknown>);
    return { task: getTask(db, id), session_id: res.body.id };
  });
}
