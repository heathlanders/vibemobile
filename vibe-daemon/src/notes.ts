// Per-project notes / TODO list (proposal 31). Short text items with a done
// checkbox, stored in the daemon DB (never in the repo). Pure DB CRUD behind the
// auth gate — mirrors prompts.ts.

import { randomUUID } from "node:crypto";
import type { FastifyInstance } from "fastify";
import type { DB } from "./db.js";
import { logEvent, type Device } from "./auth.js";

const nowIso = () => new Date().toISOString();
const COLS = "id, project_id, text, done, created_at, updated_at";
export const MAX_NOTE_CHARS = 4000;

type NoteBody = { text?: unknown; done?: unknown };

// Returns the trimmed text, or an error message.
function checkText(text: unknown): string | { error: string } {
  if (typeof text !== "string" || !text.trim()) return { error: "text required" };
  if (text.length > MAX_NOTE_CHARS) return { error: "note too long" };
  return text.trim();
}

const toJson = (row: any) => (row ? { ...row, done: !!row.done } : row);

export function registerNoteRoutes(app: FastifyInstance, db: DB): void {
  const get = (id: string) => toJson(db.prepare(`SELECT ${COLS} FROM notes WHERE id = ?`).get(id));
  const device = (req: unknown) => (req as { device?: Device }).device?.id ?? null;

  // Open items first (oldest first, like a TODO list), then done ones (most
  // recently ticked first).
  app.get("/projects/:id/notes", async (req, reply) => {
    const { id } = req.params as { id: string };
    if (!db.prepare("SELECT 1 FROM projects WHERE id = ?").get(id)) {
      return reply.code(404).send({ error: "project not found" });
    }
    return db
      .prepare(
        `SELECT ${COLS} FROM notes WHERE project_id = ?
         ORDER BY done ASC,
                  CASE WHEN done = 0 THEN created_at END ASC,
                  CASE WHEN done = 1 THEN updated_at END DESC`,
      )
      .all(id)
      .map(toJson);
  });

  app.post("/projects/:id/notes", async (req, reply) => {
    const { id: projectId } = req.params as { id: string };
    if (!db.prepare("SELECT 1 FROM projects WHERE id = ?").get(projectId)) {
      return reply.code(404).send({ error: "project not found" });
    }
    const text = checkText(((req.body ?? {}) as NoteBody).text);
    if (typeof text !== "string") return reply.code(400).send(text);
    const id = randomUUID();
    const ts = nowIso();
    db.prepare(`INSERT INTO notes (${COLS}) VALUES (?,?,?,0,?,?)`).run(id, projectId, text, ts, ts);
    logEvent(db, "note.create", device(req), id);
    return reply.code(201).send(get(id));
  });

  // Partial update: text and/or done.
  app.put("/notes/:id", async (req, reply) => {
    const { id } = req.params as { id: string };
    const existing = db.prepare("SELECT * FROM notes WHERE id = ?").get(id) as any;
    if (!existing) return reply.code(404).send({ error: "not found" });
    const b = (req.body ?? {}) as NoteBody;
    let text = existing.text as string;
    if (b.text !== undefined) {
      const t = checkText(b.text);
      if (typeof t !== "string") return reply.code(400).send(t);
      text = t;
    }
    if (b.done !== undefined && typeof b.done !== "boolean") {
      return reply.code(400).send({ error: "done must be a boolean" });
    }
    const done = b.done === undefined ? existing.done : b.done ? 1 : 0;
    db.prepare("UPDATE notes SET text = ?, done = ?, updated_at = ? WHERE id = ?").run(text, done, nowIso(), id);
    logEvent(db, "note.update", device(req), id);
    return get(id);
  });

  app.delete("/notes/:id", async (req, reply) => {
    const { id } = req.params as { id: string };
    db.prepare("DELETE FROM notes WHERE id = ?").run(id);
    logEvent(db, "note.delete", device(req), id);
    return reply.code(204).send(); // idempotent
  });
}
