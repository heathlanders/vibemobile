// Conversation fork — "branch from here" (proposal 42, M14 spike).
//
// POST /sessions/:id/fork {messageId, at?} copies the conversation up to a chosen point
// into a NEW session that resumes independently, so you can try a different direction
// without losing the original. The SDK does the transcript work (forkSession, fresh uuids,
// original untouched); we copy our own history rows to match and create the row.
//
//   at:"after"  (default) keep the chosen turn AND the reply to it
//   at:"before" keep everything before the chosen user message (i.e. "edit this one")
//
// The cut is expressed in SDK message uuids: the transcript keeps the uuid we supplied on
// each streamed user message (messages.sdk_uuid, ADR 0023), and a turn ends at the message
// just before the NEXT such uuid.

import { randomUUID } from "node:crypto";
import type { FastifyInstance } from "fastify";
import { forkSession, getSessionMessages } from "@anthropic-ai/claude-agent-sdk";
import type { DB } from "./db.js";
import { logEvent, type Device } from "./auth.js";
import type { EngineRegistry } from "./engine.js";
import { isNativeProvider, providerFor } from "./gateway.js";
import { newId } from "./sessions.js";
import { pathInRoots } from "./paths.js";

export type ForkDeps = {
  fork: (sessionId: string, o: { dir: string; upToMessageId?: string; title?: string }) => Promise<{ sessionId: string }>;
  messages: (sessionId: string, o: { dir: string }) => Promise<{ uuid: string; type: string }[]>;
};
const realDeps: ForkDeps = {
  fork: (sid, o) => forkSession(sid, o),
  messages: (sid, o) => getSessionMessages(sid, o) as Promise<{ uuid: string; type: string }[]>,
};

let override: ForkDeps | null = null;
/** Tests only: script the SDK's forkSession / getSessionMessages. */
export function _setForkDepsForTest(d: ForkDeps | null): void {
  override = d;
}

type Row = { id: string; role: string; content: string | null; tool_json: string | null; ts: string; sdk_uuid: string | null };

/**
 * Where to cut, in our rows and in the SDK transcript. Pure → unit-tested.
 * Returns the number of leading rows to copy and the transcript uuid to cut at
 * (undefined = copy everything), or an error string.
 */
export function planFork(
  rows: Row[],
  transcript: { uuid: string }[],
  messageId: string,
  at: "after" | "before",
): { rowCount: number; upToMessageId?: string } | { error: string } {
  const i = rows.findIndex((r) => r.id === messageId);
  const target = rows[i];
  if (!target || target.role !== "user" || !target.sdk_uuid) return { error: "no checkpoint for that message" };
  const pos = (uuid: string) => transcript.findIndex((m) => m.uuid === uuid);

  if (at === "before") {
    const p = pos(target.sdk_uuid);
    if (p < 0) return { error: "that message is not in the saved conversation" };
    if (p === 0) return { error: "there is nothing before the first message to branch from" };
    return { rowCount: i, upToMessageId: transcript[p - 1].uuid };
  }

  // after: up to (not including) the next user turn; the SDK cut is the message before it.
  const next = rows.findIndex((r, k) => k > i && r.role === "user");
  if (next < 0) return { rowCount: rows.length }; // last turn: everything
  const nextUuid = rows[next].sdk_uuid;
  if (!nextUuid) return { error: "a later message has no checkpoint (sent from a terminal?) — branch from an earlier one" };
  const p = pos(nextUuid);
  if (p < 1) return { error: "the saved conversation is out of step with the chat" };
  return { rowCount: next, upToMessageId: transcript[p - 1].uuid };
}

export function registerForkRoute(app: FastifyInstance, db: DB, registry: EngineRegistry, deps: ForkDeps = realDeps): void {
  app.post("/sessions/:id/fork", { config: { rateLimit: { max: 10, timeWindow: "1 minute" } } }, async (req, reply) => {
    const { id } = req.params as { id: string };
    const { messageId, at = "after" } = (req.body ?? {}) as { messageId?: unknown; at?: unknown };
    if (typeof messageId !== "string" || (at !== "after" && at !== "before")) {
      return reply.code(400).send({ error: "messageId (string) and optional at ('after'|'before') required" });
    }
    const deviceId = (req as { device?: Device }).device?.id ?? null;

    const s = db
      .prepare(
        "SELECT s.*, p.path AS project_path FROM sessions s JOIN projects p ON p.id = s.project_id WHERE s.id = ? AND s.kind = 'claude'",
      )
      .get(id) as
      | { id: string; project_id: string; title: string | null; model: string | null; mode: string | null; effort: string | null; claude_session_id: string | null; worktree_path: string | null; project_path: string }
      | undefined;
    if (!s) return reply.code(404).send({ error: "not found" });
    if (!pathInRoots(s.project_path)) return reply.code(403).send({ error: "path out of bounds" });
    if (s.worktree_path) return reply.code(400).send({ error: "forking an isolated (worktree) session isn't supported yet" });
    if (s.model && isNativeProvider(providerFor(s.model))) return reply.code(400).send({ error: "this engine can't be forked" });
    if (!s.claude_session_id) return reply.code(409).send({ error: "nothing to branch from yet — send a message first" });
    if (registry.get(id)?.busy?.()) return reply.code(409).send({ error: "a turn is running — wait for it to finish" });

    const rows = db
      .prepare("SELECT id, role, content, tool_json, ts, sdk_uuid FROM messages WHERE session_id = ? ORDER BY ts, rowid")
      .all(id) as Row[];

    let plan;
    try {
      const transcript = await (override ?? deps).messages(s.claude_session_id, { dir: s.project_path });
      plan = planFork(rows, transcript, messageId, at);
    } catch {
      return reply.code(500).send({ error: "could not read the saved conversation" });
    }
    if ("error" in plan) return reply.code(plan.error.startsWith("no checkpoint") ? 404 : 409).send({ error: plan.error });

    let forkId: string;
    try {
      forkId = (await (override ?? deps).fork(s.claude_session_id, { dir: s.project_path, upToMessageId: plan.upToMessageId, title: `${s.title ?? "Session"} (branch)` })).sessionId;
    } catch {
      return reply.code(500).send({ error: "could not branch the conversation" });
    }

    const newSession = newId();
    const created_at = new Date().toISOString();
    const title = `↳ ${s.title ?? "Session"}`.slice(0, 120);
    db.transaction(() => {
      // 'stale' = resumable but not running: attaching it makes it live (and enforces the cap).
      db.prepare(
        "INSERT INTO sessions (id, project_id, kind, title, status, created_at, model, mode, effort, claude_session_id) VALUES (?,?,?,?,?,?,?,?,?,?)",
      ).run(newSession, s.project_id, "claude", title, "stale", created_at, s.model, s.mode, s.effort, forkId);
      const ins = db.prepare("INSERT INTO messages (id, session_id, role, content, tool_json, ts) VALUES (?,?,?,?,?,?)");
      // sdk_uuid is NOT copied: the fork's messages have fresh uuids, and file checkpoints don't follow a fork.
      for (const r of rows.slice(0, plan.rowCount)) ins.run(randomUUID(), newSession, r.role, r.content, r.tool_json, r.ts);
    })();
    logEvent(db, "session.fork", deviceId, `${id}->${newSession}:${at}:${plan.rowCount}`);
    return reply.code(201).send({ id: newSession, project_id: s.project_id, kind: "claude", title, status: "stale", created_at, model: s.model, copied: plan.rowCount });
  });
}
