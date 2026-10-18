// Merge queue REST (ADR 0032), shaped like task-routes.ts. Phone-only: nothing here is a
// peer tool, and the global bearer gate in app.ts covers every route.

import type { FastifyInstance, FastifyReply } from "fastify";
import type { DB } from "./db.js";
import type { Device } from "./auth.js";
import { approve, enqueue, listItems, reject, requeue, type MergeRegistry, type Out } from "./merge-queue.js";

export function registerMergeQueueRoutes(app: FastifyInstance, db: DB, deps: { registry: MergeRegistry }): void {
  const d = { db, registry: deps.registry };
  const device = (req: unknown) => (req as { device?: Device }).device?.id ?? null;
  const limit = { config: { rateLimit: { max: 30, timeWindow: "1 minute" } } };
  const send = (reply: FastifyReply, out: Out, okCode = 200) => (out.ok ? reply.code(okCode).send(out.value) : reply.code(out.status).send({ error: out.error }));

  app.get("/projects/:id/merge-queue", async (req, reply) => {
    const { id } = req.params as { id: string };
    if (!db.prepare("SELECT 1 FROM projects WHERE id = ?").get(id)) return reply.code(404).send({ error: "project not found" });
    return listItems(db, id);
  });

  app.post("/tasks/:id/enqueue", limit, async (req, reply) =>
    send(reply, await enqueue(d, (req.params as { id: string }).id, device(req)), 201),
  );

  app.post("/merge-queue/:id/approve", limit, async (req, reply) =>
    send(reply, await approve(d, (req.params as { id: string }).id, ((req.body ?? {}) as { sha?: unknown }).sha, device(req))),
  );

  app.post("/merge-queue/:id/reject", limit, async (req, reply) => send(reply, reject(d, (req.params as { id: string }).id, device(req))));

  app.post("/merge-queue/:id/requeue", limit, async (req, reply) => send(reply, requeue(d, (req.params as { id: string }).id, device(req))));
}
