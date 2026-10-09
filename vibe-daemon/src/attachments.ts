// Image attachments for claude turns (proposal 16, session-rest.md). A user turn
// can carry images; the binary is uploaded here over REST (not the JSON event
// channel) and referenced by id in the `user` WS frame. Blobs are stored as a
// SQLite BLOB (cascade-deleted with the session) — no filesystem write surface.
//
// Security (security.md #8): the media type is sniffed from MAGIC BYTES, never
// the client's Content-Type or a filename; a per-parser bodyLimit caps the size
// before buffering; every upload is audited. Auth is the global bearer hook.

import { randomBytes } from "node:crypto";
import type { FastifyError, FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import type { DB } from "./db.js";
import { logEvent, type Device } from "./auth.js";

const newId = () => "a_" + randomBytes(6).toString("hex");
const nowIso = () => new Date().toISOString();
const MAX_BYTES = Number(process.env.VIBE_MAX_ATTACH_BYTES ?? 5 * 1024 * 1024);
const ACCEPTED = ["image/png", "image/jpeg", "image/webp", "image/gif", "application/octet-stream"];

// Identify the image type from its leading bytes. Returns null for anything not
// in the png/jpeg/webp/gif allowlist — the declared Content-Type is untrusted.
export function sniffMediaType(b: Buffer): string | null {
  if (b.length >= 8 && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47) return "image/png";
  if (b.length >= 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return "image/jpeg";
  if (b.length >= 12 && b.toString("ascii", 0, 4) === "RIFF" && b.toString("ascii", 8, 12) === "WEBP")
    return "image/webp";
  if (b.length >= 6 && (b.toString("ascii", 0, 6) === "GIF87a" || b.toString("ascii", 0, 6) === "GIF89a"))
    return "image/gif";
  return null;
}

export type StoreResult = { attachmentId: string; mediaType: string } | { reject: "too_large" | "unsupported_type" };

// Validate (size cap + magic-byte sniff) and store one image blob for a session.
// Shared by the upload route and tool-result images (proposal 33) so both paths
// enforce the same gate.
export function storeAttachment(db: DB, sessionId: string, body: Buffer): StoreResult {
  if (body.length > MAX_BYTES) return { reject: "too_large" };
  const mediaType = sniffMediaType(body);
  if (!mediaType) return { reject: "unsupported_type" };
  const attachmentId = newId();
  db.prepare("INSERT INTO attachments (id, session_id, media_type, data, created_at) VALUES (?,?,?,?,?)").run(
    attachmentId,
    sessionId,
    mediaType,
    body,
    nowIso(),
  );
  return { attachmentId, mediaType };
}

// Image blocks in a tool_result (Read on a PNG, screenshot MCP tools) — proposal 33.
// Each is stored through storeAttachment() (sniff + size gate); rejects are
// audited and dropped. Capped per result. Shared by the live claude engine, the
// CLI mirror and the transcript import. An identical blob already stored for this
// session is reused: the mirror re-imports the whole transcript on every attach.
const MAX_TOOL_IMAGES = 4;
export function toolResultImages(db: DB, sessionId: string, content: unknown): string[] {
  if (!Array.isArray(content)) return [];
  const ids: string[] = [];
  for (const c of content) {
    if (ids.length >= MAX_TOOL_IMAGES) break;
    if (c?.type !== "image" || c.source?.type !== "base64" || typeof c.source.data !== "string") continue;
    const buf = Buffer.from(c.source.data, "base64");
    const same = db.prepare("SELECT id FROM attachments WHERE session_id = ? AND data = ?").get(sessionId, buf) as
      | { id: string }
      | undefined;
    if (same) {
      ids.push(same.id);
      continue;
    }
    const r = storeAttachment(db, sessionId, buf);
    if ("reject" in r) logEvent(db, "attachment.reject", null, `${sessionId}:tool_${r.reject}:${buf.length}`);
    else ids.push(r.attachmentId);
  }
  return ids;
}

export function registerAttachmentRoutes(app: FastifyInstance, db: DB): void {
  // Collect the raw image body as a Buffer. We validate by magic bytes, so the
  // declared type is only a hint; bodyLimit rejects oversize before buffering.
  app.addContentTypeParser(ACCEPTED, { parseAs: "buffer", bodyLimit: MAX_BYTES }, (_req, body, done) =>
    done(null, body),
  );

  // Rejections are audited too (`attachment.reject`, `<session>:<reason>:<bytes>`)
  // so a failed paste/upload is debuggable from the audit log.
  const reject = (req: FastifyRequest, reason: string, bytes: number) =>
    logEvent(
      db,
      "attachment.reject",
      (req as { device?: Device }).device?.id ?? null,
      `${(req.params as { id: string }).id}:${reason}:${bytes}`,
    );

  // Upload an image for a claude session → { attachmentId, mediaType }. The id is
  // server-minted; the client puts it in the `user` frame's `images` (claude-ws.md).
  // The bodyLimit 413 fires in the parser, before the handler — catch it here.
  const errorHandler = (err: FastifyError, req: FastifyRequest, reply: FastifyReply) => {
    if (err.code !== "FST_ERR_CTP_BODY_TOO_LARGE") throw err;
    reject(req, "too_large", Number(req.headers["content-length"] ?? 0));
    return reply.code(413).send({ error: "too large" });
  };
  app.post("/sessions/:id/attachments", { errorHandler }, async (req, reply) => {
    const { id } = req.params as { id: string };
    const row = db.prepare("SELECT id, kind FROM sessions WHERE id = ?").get(id) as
      | { id: string; kind: string }
      | undefined;
    if (!row || row.kind !== "claude") return reply.code(404).send({ error: "no claude session" });

    const body = req.body as Buffer;
    if (!Buffer.isBuffer(body) || body.length === 0) return reply.code(400).send({ error: "empty body" });
    const r = storeAttachment(db, id, body);
    if ("reject" in r) {
      reject(req, r.reject, body.length);
      return r.reject === "too_large"
        ? reply.code(413).send({ error: "too large" })
        : reply.code(415).send({ error: "unsupported image type" });
    }
    logEvent(db, "attachment.upload", (req as { device?: Device }).device?.id ?? null, `${id}:${r.mediaType}:${body.length}`);
    return reply.code(201).send(r);
  });

  // Serve a stored blob (client thumbnail / history redraw). Bearer-gated like
  // every route; the id alone is the capability — no path is ever derived from it.
  app.get("/attachments/:id", async (req, reply) => {
    const { id } = req.params as { id: string };
    const row = db.prepare("SELECT media_type, data FROM attachments WHERE id = ?").get(id) as
      | { media_type: string; data: Buffer }
      | undefined;
    if (!row) return reply.code(404).send({ error: "not found" });
    return reply.header("Content-Type", row.media_type).send(row.data);
  });
}
