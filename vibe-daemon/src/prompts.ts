// Prompt library CRUD (M4, PLAN §3). Reusable templates with {{var}} placeholders,
// global (project_id null) or scoped to a project, reusable across projects. Pure
// DB CRUD behind the auth gate — mirrors the device/project handlers in app.ts.

import { randomUUID } from "node:crypto";
import type { FastifyInstance } from "fastify";
import type { DB } from "./db.js";
import { logEvent, type Device } from "./auth.js";
import { ImproveBusy, MAX_PROMPT_CHARS, improvePrompt, type ImproveMode } from "./prompt-improve.js";

const nowIso = () => new Date().toISOString();
const COLS = "id, title, body, tags, project_id, vars_json, created_at, updated_at, use_count, last_used_at, always_apply";
// Insert columns (use_count/last_used_at take their defaults).
const INSERT_COLS = "id, title, body, tags, project_id, vars_json, created_at, updated_at, always_apply";

type ImproveFn = (text: string, cwd: string, mode?: ImproveMode) => Promise<string>;

// An always-apply prompt is sent verbatim in every session's system prompt (ADR 0031),
// so there is nobody to fill {{vars}}.
const VAR_RE = /\{\{\s*[a-zA-Z0-9_]+\s*\}\}/;

// SQLite stores always_apply as 0/1; the API speaks booleans.
const out = <T extends { always_apply?: unknown } | undefined>(row: T): T =>
  row ? ({ ...row, always_apply: !!row.always_apply } as T) : row;

type PromptBody = {
  title?: string;
  body?: string;
  tags?: string;
  project_id?: string | null;
  vars_json?: string | null;
  always_apply?: boolean;
};

export function registerPromptRoutes(app: FastifyInstance, db: DB, improve: ImproveFn = (text, cwd, mode) => improvePrompt(text, cwd, undefined, mode)): void {
  // Create. project_id null = global; if set it must exist.
  app.post("/prompts", async (req, reply) => {
    const { title, body, tags, project_id, vars_json, always_apply } = (req.body ?? {}) as PromptBody;
    if (!title || !body) return reply.code(400).send({ error: "title and body required" });
    if (always_apply !== undefined && typeof always_apply !== "boolean") return reply.code(400).send({ error: "always_apply must be a boolean" });
    if (always_apply && VAR_RE.test(body)) return reply.code(400).send({ error: "an always-apply prompt cannot contain {{placeholders}}" });
    if (project_id && !db.prepare("SELECT 1 FROM projects WHERE id = ?").get(project_id)) {
      return reply.code(404).send({ error: "project not found" });
    }
    const id = randomUUID();
    const ts = nowIso();
    db.prepare(
      `INSERT INTO prompts (${INSERT_COLS}) VALUES (?,?,?,?,?,?,?,?,?)`,
    ).run(id, title, body, tags ?? null, project_id ?? null, vars_json ?? null, ts, ts, always_apply ? 1 : 0);
    const deviceId = (req as { device?: Device }).device?.id ?? null;
    logEvent(db, "prompt.create", deviceId, id);
    if (always_apply) logEvent(db, "prompt.always_apply", deviceId, `${id}=on`);
    return reply.code(201).send(out(db.prepare(`SELECT ${COLS} FROM prompts WHERE id = ?`).get(id) as any));
  });

  // List. ?project_id=… → globals + that project's prompts; no filter → all.
  // ?sort=used → most-used first (ADR 0018); default most recently edited.
  app.get("/prompts", async (req) => {
    const { project_id, sort } = req.query as { project_id?: string; sort?: string };
    const order = sort === "used" ? "use_count DESC, last_used_at DESC, updated_at DESC" : "updated_at DESC";
    if (project_id) {
      return (db
        .prepare(`SELECT ${COLS} FROM prompts WHERE project_id IS NULL OR project_id = ? ORDER BY ${order}`)
        .all(project_id) as any[]).map(out);
    }
    return (db.prepare(`SELECT ${COLS} FROM prompts ORDER BY ${order}`).all() as any[]).map(out);
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
    const { text, mode } = (req.body ?? {}) as { text?: unknown; mode?: unknown };
    if (typeof text !== "string" || !text.trim()) return reply.code(400).send({ error: "text required" });
    if (mode !== undefined && mode !== "improve" && mode !== "deeper") return reply.code(400).send({ error: "mode must be improve or deeper" });
    if (text.length > MAX_PROMPT_CHARS) return reply.code(413).send({ error: "prompt too long" });
    try {
      const improved = await improve(text, process.env.HOME ?? "/tmp", mode ?? "improve");
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
    return out(row as any);
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
    if (b.always_apply !== undefined && typeof b.always_apply !== "boolean") {
      return reply.code(400).send({ error: "always_apply must be a boolean" });
    }
    const alwaysApply = b.always_apply === undefined ? !!existing.always_apply : b.always_apply;
    const newBody = b.body ?? existing.body;
    if (alwaysApply && VAR_RE.test(newBody)) {
      return reply.code(400).send({ error: "an always-apply prompt cannot contain {{placeholders}}" });
    }
    db.prepare(
      `UPDATE prompts SET title = ?, body = ?, tags = ?, project_id = ?, vars_json = ?, always_apply = ?, updated_at = ? WHERE id = ?`,
    ).run(
      b.title ?? existing.title,
      newBody,
      b.tags ?? existing.tags,
      b.project_id === undefined ? existing.project_id : b.project_id,
      b.vars_json ?? existing.vars_json,
      alwaysApply ? 1 : 0,
      nowIso(),
      id,
    );
    const deviceId = (req as { device?: Device }).device?.id ?? null;
    logEvent(db, "prompt.update", deviceId, id);
    if (alwaysApply !== !!existing.always_apply) logEvent(db, "prompt.always_apply", deviceId, `${id}=${alwaysApply ? "on" : "off"}`);
    return out(db.prepare(`SELECT ${COLS} FROM prompts WHERE id = ?`).get(id) as any);
  });

  app.delete("/prompts/:id", async (req, reply) => {
    const { id } = req.params as { id: string };
    const was = db.prepare("SELECT always_apply FROM prompts WHERE id = ?").get(id) as { always_apply: number } | undefined;
    db.prepare("DELETE FROM prompts WHERE id = ?").run(id);
    const deviceId = (req as { device?: Device }).device?.id ?? null;
    logEvent(db, "prompt.delete", deviceId, id);
    if (was?.always_apply) logEvent(db, "prompt.always_apply", deviceId, `${id}=off`);
    return reply.code(204).send(); // idempotent
  });
}
