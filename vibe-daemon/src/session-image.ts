// Session image read (proposal 33, ADR 0021, security.md #23). Lets the chat show
// an image file Claude wrote or mentioned (e.g. `out/chart.png`).
//
// Scope is deliberately narrow — this is NOT a file reader:
//   - the resolved (realpath) file must sit inside THIS session's project root;
//   - regular files only, size-capped before reading;
//   - bytes are served only if their magic bytes sniff as png/jpeg/webp/gif, so
//     a text/secret file can never come back, whatever its name;
//   - rate-limited, every read audited.

import { open, realpath, stat } from "node:fs/promises";
import { isAbsolute, relative, resolve, sep } from "node:path";
import type { FastifyInstance } from "fastify";
import type { DB } from "./db.js";
import { logEvent, type Device } from "./auth.js";
import { pathInRoots } from "./paths.js";
import { sniffMediaType } from "./attachments.js";

const MAX_BYTES = Number(process.env.VIBE_MAX_ATTACH_BYTES ?? 5 * 1024 * 1024);

export function registerSessionImageRoute(app: FastifyInstance, db: DB): void {
  app.get(
    "/sessions/:id/image",
    { config: { rateLimit: { max: 120, timeWindow: "1 minute" } } },
    async (req, reply) => {
      const { id } = req.params as { id: string };
      const { path } = req.query as { path?: string };
      const row = db
        .prepare("SELECT COALESCE(s.worktree_path, p.path) AS path FROM sessions s LEFT JOIN projects p ON p.id = s.project_id WHERE s.id = ?")
        .get(id) as { path: string | null } | undefined;
      if (row === undefined) return reply.code(404).send({ error: "not found" });
      if (!row.path) return reply.code(404).send({ error: "session has no project" });
      if (!path) return reply.code(400).send({ error: "path required" });

      let root: string;
      let real: string;
      try {
        root = await realpath(row.path);
        real = await realpath(isAbsolute(path) ? path : resolve(root, path)); // symlinks resolved before scope check
      } catch {
        return reply.code(404).send({ error: "file not found" });
      }
      if (!(real.startsWith(root + sep) && pathInRoots(real))) return reply.code(403).send({ error: "path out of bounds" });

      const st = await stat(real);
      if (!st.isFile()) return reply.code(404).send({ error: "not a regular file" });
      if (st.size > MAX_BYTES) return reply.code(413).send({ error: "too large" });

      // Read at most MAX_BYTES even if the file grew since stat.
      const fh = await open(real, "r");
      let buf: Buffer;
      try {
        const b = Buffer.alloc(Math.min(st.size, MAX_BYTES));
        const { bytesRead } = await fh.read(b, 0, b.length, 0);
        buf = b.subarray(0, bytesRead);
      } finally {
        await fh.close();
      }
      const mediaType = sniffMediaType(buf);
      if (!mediaType) return reply.code(415).send({ error: "not an image" });

      logEvent(db, "file.image", (req as { device?: Device }).device?.id ?? null, `${id}:${relative(root, real)}:${buf.length}`);
      return reply.header("Content-Type", mediaType).header("Cache-Control", "no-store").send(buf);
    },
  );
}
