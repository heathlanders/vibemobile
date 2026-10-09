// File rewind route (ADR 0023, security.md). POST /sessions/:id/rewind undoes a
// user message's file edits (and everything after) via the SDK's file checkpoints.
//
// The client names a daemon `messages.id` of a USER message in this session — never
// a path or a raw SDK uuid (capability, not a file API). Every call dry-runs first;
// the SDK's absolute `filesChanged` are re-checked against the project roots before
// a real run is allowed, because a real rewind writes/deletes files the moment it runs.

import { relative } from "node:path";
import type { FastifyInstance } from "fastify";
import type { DB } from "./db.js";
import type { Device } from "./auth.js";
import { logEvent } from "./auth.js";
import type { EngineRegistry } from "./engine.js";
import { canonical, inside } from "./file-scope.js";
import { pathInRoots } from "./paths.js";

const inFlight = new Set<string>(); // sessions with a rewind running — one at a time

export function registerRewindRoute(app: FastifyInstance, db: DB, registry: EngineRegistry): void {
  app.post("/sessions/:id/rewind", async (req, reply) => {
    const { id } = req.params as { id: string };
    const { messageId, dryRun } = (req.body ?? {}) as { messageId?: unknown; dryRun?: unknown };
    if (typeof messageId !== "string" || (dryRun !== undefined && typeof dryRun !== "boolean")) {
      return reply.code(400).send({ error: "messageId (string) and optional dryRun (boolean) required" });
    }
    const deviceId = (req as { device?: Device }).device?.id ?? null;

    const sess = db
      .prepare("SELECT COALESCE(s.worktree_path, p.path) AS cwd, s.worktree_path IS NOT NULL AS wt FROM sessions s JOIN projects p ON p.id = s.project_id WHERE s.id = ? AND s.kind = 'claude'")
      .get(id) as { cwd: string; wt: number } | undefined;
    if (!sess) return reply.code(404).send({ error: "not found" });

    // Capability: a user message of THIS session that was sent with a checkpoint uuid.
    const msg = db
      .prepare("SELECT sdk_uuid FROM messages WHERE id = ? AND session_id = ? AND role = 'user'")
      .get(messageId, id) as { sdk_uuid: string | null } | undefined;
    if (!msg?.sdk_uuid) return reply.code(404).send({ error: "no checkpoint for that message" });

    const session = registry.get(id);
    if (!session) return reply.code(409).send({ error: "session not running — open the chat first" });
    if (!session.rewind) return reply.code(400).send({ error: "this engine does not support rewind" });
    if (session.busy?.()) return reply.code(409).send({ error: "a turn is running — interrupt it first" });
    if (inFlight.has(id)) return reply.code(409).send({ error: "a rewind is already running" });

    inFlight.add(id);
    try {
      // 1. Always dry-run first.
      const dry = await session.rewind(msg.sdk_uuid, true);
      if (!dry.canRewind) return { canRewind: false, error: dry.error ?? "cannot rewind", dryRun: true };

      // 2. Scope check on the absolute paths the SDK says it would touch.
      const cwd = canonical(sess.cwd);
      const abs = dry.filesChanged ?? [];
      const out = abs.filter((p) => {
        const c = canonical(p);
        // A worktree session may only touch its own checkout (ADR 0022).
        return !inside(c, cwd) && (sess.wt === 1 || !pathInRoots(c));
      });
      if (out.length) {
        logEvent(db, "session.rewind.denied", deviceId, `${id}:${out.length} out of scope`);
        return reply.code(403).send({ error: "rewind would touch files outside the project roots", files: out });
      }
      const files = abs.map((p) => {
        const c = canonical(p);
        return inside(c, cwd) ? relative(cwd, c) : c;
      });

      if (dryRun !== false) {
        logEvent(db, "session.rewind.dry", deviceId, `${id}:${messageId}:${files.length}`);
        return { canRewind: true, dryRun: true, filesChanged: files, insertions: dry.insertions, deletions: dry.deletions };
      }

      // 3. Real run — re-check no turn started while we were dry-running.
      if (session.busy?.()) return reply.code(409).send({ error: "a turn started — try again" });
      const real = await session.rewind(msg.sdk_uuid, false);
      if (!real.canRewind) return reply.code(500).send({ canRewind: false, error: real.error ?? "rewind failed" });
      logEvent(db, "session.rewind", deviceId, `${id}:${messageId}:${files.length}`);
      session.announceRewound?.(messageId, files);
      // A real run returns no file list (M8 spike) — report the dry-run list.
      return {
        canRewind: true,
        dryRun: false,
        filesChanged: files,
        insertions: dry.insertions,
        deletions: dry.deletions,
        skippedLinks: real.skippedLinks ?? 0,
      };
    } finally {
      inFlight.delete(id);
    }
  });
}
