// Prompt library CRUD (M4, PLAN §3). Reusable templates with {{var}} placeholders,
// global (project_id null) or scoped to a project, reusable across projects. Pure
// DB CRUD behind the auth gate — mirrors the device/project handlers in app.ts.

import { randomUUID } from "node:crypto";
import type { FastifyInstance } from "fastify";
import type { DB } from "./db.js";
import { logEvent, type Device } from "./auth.js";
import { ImproveBusy, MAX_PROMPT_CHARS, improvePrompt } from "./prompt-improve.js";

const nowIso = () => new Date().toISOString();
const COLS = "id, title, body, tags, project_id, vars_json, created_at, updated_at, use_count, last_used_at";
// Insert columns (use_count/last_used_at take their defaults).
const INSERT_COLS = "id, title, body, tags, project_id, vars_json, created_at, updated_at";

type ImproveFn = (text: string, cwd: string) => Promise<string>;

type PromptBody = {
  title?: string;
  body?: string;
  tags?: string;
  project_id?: string | null;
  vars_json?: string | null;
};

export function registerPromptRoutes(app: FastifyInstance, db: DB, improve: ImproveFn = improvePrompt): void {
  // Create. project_id null = global; if set it must exist.
  app.post("/prompts", async (req, reply) => {
    const { title, body, tags, project_id, vars_json } = (req.body ?? {}) as PromptBody;
    if (!title || !body) return reply.code(400).send({ error: "title and body required" });
    if (project_id && !db.prepare("SELECT 1 FROM projects WHERE id = ?").get(project_id)) {
      return reply.code(404).send({ error: "project not found" });
    }
    const id = randomUUID();
    const ts = nowIso();
    db.prepare(
      `INSERT INTO prompts (${INSERT_COLS}) VALUES (?,?,?,?,?,?,?,?)`,
    ).run(id, title, body, tags ?? null, project_id ?? null, vars_json ?? null, ts, ts);
    logEvent(db, "prompt.create", (req as { device?: Device }).device?.id ?? null, id);
    return reply.code(201).send(db.prepare(`SELECT ${COLS} FROM prompts WHERE id = ?`).get(id));
  });

  // List. ?project_id=… → globals + that project's prompts; no filter → all.
  // ?sort=used → most-used first (ADR 0018); default most recently edited.
  app.get("/prompts", async (req) => {
    const { project_id, sort } = req.query as { project_id?: string; sort?: string };
    const order = sort === "used" ? "use_count DESC, last_used_at DESC, updated_at DESC" : "updated_at DESC";
    if (project_id) {
      return db
        .prepare(`SELECT ${COLS} FROM prompts WHERE project_id IS NULL OR project_id = ? ORDER BY ${order}`)
        .all(project_id);
    }
    return db.prepare(`SELECT ${COLS} FROM prompts ORDER BY ${order}`).all();
  });

  // Past user turns across every session (ADR 0018) — the raw material for new
  // library entries. Identical texts collapse into one row with a count. LIKE is
  // plenty at personal-DB scale (hundreds to low thousands of user rows).
  app.get("/prompts/history", async (req) => {
    const { q, limit } = req.query as { q?: string; limit?: string };
    const max = Math.min(Math.max(Number(limit ?? 50) || 50, 1), 200);
    const like = q?.trim() ? `%${q.trim().replace(/[\\%_]/g, (c) => "\\" + c)}%` : "%";
    return db
      .prepare(
        `SELECT m.content AS text, COUNT(*) AS times, MAX(m.ts) AS last_ts,
                (SELECT p.name FROM sessions s JOIN projects p ON p.id = s.project_id WHERE s.id = m.session_id) AS project
         FROM messages m
         WHERE m.role = 'user' AND m.content IS NOT NULL AND length(trim(m.content)) > 0
           AND m.content LIKE ? ESCAPE '\\'
         GROUP BY m.content ORDER BY last_ts DESC LIMIT ?`,
      )
      .all(like, max);
  });

  // Rewrite a prompt against the prompting checklist (ADR 0018). Text in, text
  // out — the client shows it for review; nothing is saved here.
  app.post("/prompts/improve", async (req, reply) => {
    const { text } = (req.body ?? {}) as { text?: unknown };
    if (typeof text !== "string" || !text.trim()) return reply.code(400).send({ error: "text required" });
    if (text.length > MAX_PROMPT_CHARS) return reply.code(413).send({ error: "prompt too long" });
    try {
      const improved = await improve(text, process.env.HOME ?? "/tmp");
      logEvent(db, "prompt.improve", (req as { device?: Device }).device?.id ?? null);
      return { text: improved };
    } catch (e) {
      if (e instanceof ImproveBusy) return reply.code(429).send({ error: "an improve is already running" });
      return reply.code(502).send({ error: "could not improve the prompt" });
    }
  });

  // Count a use (the library's "most used" sort).
  app.post("/prompts/:id/use", async (req, reply) => {
    const { id } = req.params as { id: string };
    const info = db.prepare("UPDATE prompts SET use_count = use_count + 1, last_used_at = ? WHERE id = ?").run(nowIso(), id);
    if (info.changes === 0) return reply.code(404).send({ error: "not found" });
    return reply.code(204).send();
  });

  app.get("/prompts/:id", async (req, reply) => {
    const { id } = req.params as { id: string };
    const row = db.prepare(`SELECT ${COLS} FROM prompts WHERE id = ?`).get(id);
    if (!row) return reply.code(404).send({ error: "not found" });
    return row;
  });

  // Update mutable fields, bump updated_at. Each field is optional (partial edit).
  app.put("/prompts/:id", async (req, reply) => {
    const { id } = req.params as { id: string };
    const existing = db.prepare("SELECT * FROM prompts WHERE id = ?").get(id) as any;
    if (!existing) return reply.code(404).send({ error: "not found" });
    const b = (req.body ?? {}) as PromptBody;
    if (b.project_id && !db.prepare("SELECT 1 FROM projects WHERE id = ?").get(b.project_id)) {
      return reply.code(404).send({ error: "project not found" });
    }
    db.prepare(
      `UPDATE prompts SET title = ?, body = ?, tags = ?, project_id = ?, vars_json = ?, updated_at = ? WHERE id = ?`,
    ).run(
      b.title ?? existing.title,
      b.body ?? existing.body,
      b.tags ?? existing.tags,
      b.project_id === undefined ? existing.project_id : b.project_id,
      b.vars_json ?? existing.vars_json,
      nowIso(),
      id,
    );
    logEvent(db, "prompt.update", (req as { device?: Device }).device?.id ?? null, id);
    return db.prepare(`SELECT ${COLS} FROM prompts WHERE id = ?`).get(id);
  });

  app.delete("/prompts/:id", async (req, reply) => {
    const { id } = req.params as { id: string };
    db.prepare("DELETE FROM prompts WHERE id = ?").run(id);
    logEvent(db, "prompt.delete", (req as { device?: Device }).device?.id ?? null, id);
    return reply.code(204).send(); // idempotent
  });
}
