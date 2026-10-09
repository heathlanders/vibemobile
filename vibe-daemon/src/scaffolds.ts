// Scaffold library CRUD (proposal 17). A scaffold is a named set of files
// ([{path, body}]) applied to a new project dir on create (projects.ts) — the
// multi-file analogue of the prompt library (prompts.ts). Pure DB CRUD behind
// the auth gate. files_json is validated here so create can trust stored rows.

import { randomUUID } from "node:crypto";
import type { FastifyInstance } from "fastify";
import type { DB } from "./db.js";
import { logEvent, type Device } from "./auth.js";
import { validateScaffoldFiles } from "./scaffold-files.js";

const nowIso = () => new Date().toISOString();
const COLS = "id, name, description, files_json, created_at, updated_at";

type ScaffoldBody = {
  name?: string;
  description?: string | null;
  files?: { path?: string; body?: string }[];
};

export function registerScaffoldRoutes(app: FastifyInstance, db: DB): void {
  // Create. `files` is the editable shape; we store it as files_json once valid.
  app.post("/scaffolds", async (req, reply) => {
    const { name, description, files } = (req.body ?? {}) as ScaffoldBody;
    if (!name || !Array.isArray(files)) return reply.code(400).send({ error: "name and files[] required" });
    const err = validateScaffoldFiles(files);
    if (err) return reply.code(400).send({ error: err });
    const id = randomUUID();
    const ts = nowIso();
    db.prepare(`INSERT INTO scaffolds (${COLS}) VALUES (?,?,?,?,?,?)`).run(
      id,
      name,
      description ?? null,
      JSON.stringify(files),
      ts,
      ts,
    );
    logEvent(db, "scaffold.create", (req as { device?: Device }).device?.id ?? null, id);
    return reply.code(201).send(db.prepare(`SELECT ${COLS} FROM scaffolds WHERE id = ?`).get(id));
  });

  app.get("/scaffolds", async () =>
    db.prepare(`SELECT ${COLS} FROM scaffolds ORDER BY updated_at DESC`).all(),
  );

  app.get("/scaffolds/:id", async (req, reply) => {
    const { id } = req.params as { id: string };
    const row = db.prepare(`SELECT ${COLS} FROM scaffolds WHERE id = ?`).get(id);
    if (!row) return reply.code(404).send({ error: "not found" });
    return row;
  });

  // Partial edit. Re-validate files if they're being replaced.
  app.put("/scaffolds/:id", async (req, reply) => {
    const { id } = req.params as { id: string };
    const existing = db.prepare("SELECT * FROM scaffolds WHERE id = ?").get(id) as any;
    if (!existing) return reply.code(404).send({ error: "not found" });
    const b = (req.body ?? {}) as ScaffoldBody;
    let files_json = existing.files_json;
    if (b.files !== undefined) {
      if (!Array.isArray(b.files)) return reply.code(400).send({ error: "files must be an array" });
      const err = validateScaffoldFiles(b.files);
      if (err) return reply.code(400).send({ error: err });
      files_json = JSON.stringify(b.files);
    }
    db.prepare(
      `UPDATE scaffolds SET name = ?, description = ?, files_json = ?, updated_at = ? WHERE id = ?`,
    ).run(
      b.name ?? existing.name,
      b.description === undefined ? existing.description : b.description,
      files_json,
      nowIso(),
      id,
    );
    logEvent(db, "scaffold.update", (req as { device?: Device }).device?.id ?? null, id);
    return db.prepare(`SELECT ${COLS} FROM scaffolds WHERE id = ?`).get(id);
  });

  app.delete("/scaffolds/:id", async (req, reply) => {
    const { id } = req.params as { id: string };
    db.prepare("DELETE FROM scaffolds WHERE id = ?").run(id);
    logEvent(db, "scaffold.delete", (req as { device?: Device }).device?.id ?? null, id);
    return reply.code(204).send(); // idempotent
  });
}
