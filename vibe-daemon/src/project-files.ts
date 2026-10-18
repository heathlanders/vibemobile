// Project files: list, text read/save, binary download/upload (proposal 59, ADR 0030, security.md #33).
//
// Every route exists under BOTH /projects/:id/files… (project path) and /sessions/:id/files…
// (the session's worktree, else the project path). Paths are relative to that root and go through
// browse.ts's resolveInside/looksSecret (lexical check, realpath re-check, `.git` invisible, secrets
// refused). This is the first WRITE surface over project files, so writes are atomic (temp file in the
// target's real directory, fsync, rename), never create folders, never touch `.git` or secret-looking
// names, and are serialised per project root. Error bodies are short fixed sentences, never paths.

import { createHash, randomBytes } from "node:crypto";
import { closeSync, fsyncSync, lstatSync, openSync, statSync } from "node:fs";
import { open, rename, unlink } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import type { FastifyError, FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import type { DB } from "./db.js";
import { logEvent, type Device } from "./auth.js";
import { pathInRoots } from "./paths.js";
import { withProjectLock } from "./project-lock.js";
import { diskGuard } from "./settings.js";
import { listDir, looksSecret, resolveInside, type BrowseError } from "./browse.js";

const SNIFF_BYTES = 8192;
const MiB = 1024 * 1024;
// Read per call so tests (and an operator restart with new env) see the current value.
const cap = (name: string, dflt: number) => {
  const n = Number(process.env[name]);
  return Number.isFinite(n) && n > 0 ? n : dflt;
};
const editCap = () => cap("VIBE_MAX_EDIT_BYTES", 2 * MiB);
const downloadCap = () => cap("VIBE_MAX_DOWNLOAD_BYTES", 200 * MiB);
const uploadCap = () => cap("VIBE_MAX_UPLOAD_BYTES", 100 * MiB);

const bad = (status: number, error: string): BrowseError => ({ status, error });
const sha256 = (b: Buffer) => createHash("sha256").update(b).digest("hex");

type Located = { real: string | null; dir: string; name: string; rel: string; root: string; mode: number };

/** An existing, regular, non-secret file inside `root`. */
function locateExisting(root: string, relIn: unknown): Located | BrowseError {
  if (typeof relIn !== "string" || !relIn.trim()) return bad(400, "path required");
  const t = resolveInside(root, relIn);
  if ("status" in t) return t;
  if (looksSecret(relIn) || looksSecret(t.real)) return bad(403, "this file looks like a secret");
  let st;
  try {
    st = statSync(t.real);
  } catch {
    return bad(404, "not found");
  }
  if (!st.isFile()) return bad(400, "not a file");
  return { real: t.real, dir: dirname(t.real), name: basename(t.real), rel: t.rel, root: t.root, mode: st.mode & 0o777 };
}

/** An existing file (as above) OR a not-yet-existing name inside an existing folder. */
function locate(root: string, relIn: unknown): Located | BrowseError {
  const ex = locateExisting(root, relIn);
  if (!("status" in ex) || ex.status !== 404) return ex;
  const segs = (relIn as string).replace(/^\/+|\/+$/g, "").split("/");
  const name = segs.pop() ?? "";
  if (!name || name === "." || name === ".." || /[\\\x00-\x1f\x7f]/.test(name) || Buffer.byteLength(name) > 255) return bad(400, "bad file name");
  if (name.toLowerCase() === ".git") return bad(403, "not available");
  if (looksSecret(name)) return bad(403, "this file name looks like a secret");
  const p = resolveInside(root, segs.join("/"));
  if ("status" in p) return p;
  try {
    if (!statSync(p.real).isDirectory()) return bad(404, "folder not found");
  } catch {
    return bad(404, "folder not found");
  }
  try {
    lstatSync(join(p.real, name)); // also catches a dangling symlink sitting at the name
    return bad(409, "already exists");
  } catch {
    /* free */
  }
  return { real: null, dir: p.real, name, rel: p.rel ? `${p.rel}/${name}` : name, root: p.root, mode: 0o644 };
}

const quietUnlink = (p: string) => unlink(p).catch(() => {});

async function makeTemp(dir: string, name: string, mode: number) {
  const tmp = join(dir, `.${[...name].slice(0, 40).join("")}.vibe-${randomBytes(6).toString("hex")}.tmp`);
  const fh = await open(tmp, "wx", mode);
  try {
    await fh.chmod(mode); // the umask must not narrow a copied mode
  } catch (e) {
    await fh.close().catch(() => {});
    await quietUnlink(tmp);
    throw e;
  }
  return { tmp, fh };
}

async function syncDir(dir: string) {
  try {
    const fd = openSync(dir, "r");
    try {
      fsyncSync(fd);
    } finally {
      closeSync(fd);
    }
  } catch {
    /* best effort */
  }
}

async function sha256File(path: string): Promise<string> {
  const fh = await open(path, "r");
  try {
    const h = createHash("sha256");
    for await (const c of fh.createReadStream()) h.update(c as Buffer);
    return h.digest("hex");
  } finally {
    await fh.close().catch(() => {});
  }
}

// RFC 6266 / 5987: ASCII-safe `filename=` fallback plus the real name in `filename*=`.
export function contentDisposition(name: string): string {
  const ascii = name.replace(/[^\x20-\x7e]|["\\%;]/g, "_") || "download";
  const enc = encodeURIComponent(name).replace(/['()*]/g, (c) => "%" + c.charCodeAt(0).toString(16).toUpperCase());
  return `attachment; filename="${ascii}"; filename*=UTF-8''${enc}`;
}

type Out = { status: number; body: object };

export function registerProjectFilesRoutes(app: FastifyInstance, db: DB): void {
  const rl = (max: number) => ({ config: { rateLimit: { max, timeWindow: "1 minute" } } });
  const readLimit = rl(90);
  const writeLimit = rl(30);
  const deviceId = (req: unknown) => (req as { device?: Device }).device?.id ?? null;

  // Route error handler: never let a raw fs error (which carries the absolute path) reach the client.
  const tooLarge = (err: FastifyError, _req: FastifyRequest, reply: FastifyReply) => {
    if (err.code === "FST_ERR_CTP_BODY_TOO_LARGE") return reply.code(413).send({ error: "too large" });
    if (typeof err.statusCode === "number" && err.statusCode < 500) return reply.code(err.statusCode).send({ error: "bad request" });
    return reply.code(500).send({ error: "could not write the file" });
  };

  const rootFor = (prefix: "projects" | "sessions", id: string): { root: string } | BrowseError => {
    const row =
      prefix === "projects"
        ? (db.prepare("SELECT path AS root FROM projects WHERE id = ?").get(id) as { root: string } | undefined)
        : (db
            .prepare("SELECT COALESCE(s.worktree_path, p.path) AS root FROM sessions s JOIN projects p ON p.id = s.project_id WHERE s.id = ?")
            .get(id) as { root: string } | undefined);
    if (!row) return bad(404, "not found");
    if (!pathInRoots(row.root)) return bad(403, "path out of bounds");
    return row;
  };

  const audit = (kind: string, req: unknown, prefix: string, id: string, rel: string, bytes: number) =>
    logEvent(db, kind, deviceId(req), `${prefix}:${id}:${bytes}:${rel}`);

  // Finish a write: fsync'd temp -> rename over the target, then fsync the folder.
  async function publish(tmp: string, target: string, dir: string) {
    await rename(tmp, target);
    await syncDir(dir);
  }

  // ---- text save ------------------------------------------------------------------------------

  async function saveText(root: string, body: { path?: unknown; content?: unknown; baseSha?: unknown; create?: unknown }): Promise<Out> {
    const hasSha = body.baseSha !== undefined;
    const create = body.create === true;
    if (typeof body.path !== "string" || !body.path.trim()) return { status: 400, body: { error: "path required" } };
    if (typeof body.content !== "string") return { status: 400, body: { error: "content must be text" } };
    if (hasSha === create || (hasSha && (typeof body.baseSha !== "string" || !/^[0-9a-f]{64}$/.test(body.baseSha)))) {
      return { status: 400, body: { error: "send exactly one of baseSha or create:true" } };
    }
    if (body.create !== undefined && !create) return { status: 400, body: { error: "create must be true" } };
    const bytes = Buffer.from(body.content, "utf8");
    if (bytes.length > editCap()) return { status: 413, body: { error: "too large" } };
    const path = body.path;
    return withProjectLock(root, async () => {
      const loc = locate(root, path);
      if ("status" in loc) return { status: loc.status, body: { error: loc.error } };
      if (create && loc.real) return { status: 409, body: { error: "already exists" } };
      if (!create) {
        if (!loc.real) return { status: 404, body: { error: "not found" } };
        const current = await sha256File(loc.real);
        if (current !== body.baseSha) return { status: 409, body: { error: "changed since you opened it", sha: current } };
      }
      const { tmp, fh } = await makeTemp(loc.dir, loc.name, loc.mode);
      try {
        await fh.writeFile(bytes);
        await fh.sync();
        await fh.close();
        await publish(tmp, loc.real ?? join(loc.dir, loc.name), loc.dir);
      } catch {
        await fh.close().catch(() => {});
        await quietUnlink(tmp);
        return { status: 500, body: { error: "could not write the file" } };
      }
      const st = statSync(loc.real ?? join(loc.dir, loc.name));
      return { status: 200, body: { path: loc.rel, sha: sha256(bytes), mtime: st.mtime.toISOString(), size: bytes.length } };
    });
  }

  // ---- routes (both scopes) -------------------------------------------------------------------

  for (const prefix of ["projects", "sessions"] as const) {
    const base = `/${prefix}/:id/files`;
    const scope = (req: FastifyRequest, reply: FastifyReply) => {
      const id = (req.params as { id: string }).id;
      const r = rootFor(prefix, id);
      if ("status" in r) {
        void reply.code(r.status).send({ error: r.error });
        return null;
      }
      return { id, root: r.root };
    };
    const query = (req: FastifyRequest) => req.query as { path?: unknown; overwrite?: unknown };

    app.get(base, readLimit, async (req, reply) => {
      const s = scope(req, reply);
      if (!s) return reply;
      const out = listDir(s.root, query(req).path);
      if ("status" in out) return reply.code(out.status).send({ error: out.error });
      return out;
    });

    app.get(`${base}/text`, { ...readLimit, errorHandler: tooLarge }, async (req, reply) => {
      const s = scope(req, reply);
      if (!s) return reply;
      const loc = locateExisting(s.root, query(req).path);
      if ("status" in loc) return reply.code(loc.status).send({ error: loc.error });
      let fh;
      try {
        fh = await open(loc.real!, "r");
      } catch {
        return reply.code(404).send({ error: "not found" });
      }
      try {
        const st = await fh.stat();
        if (!st.isFile()) return reply.code(400).send({ error: "not a file" });
        if (st.size > editCap()) return reply.code(413).send({ error: "too large to edit" });
        const buf = Buffer.alloc(st.size);
        let off = 0;
        while (off < buf.length) {
          const { bytesRead } = await fh.read(buf, off, buf.length - off, off);
          if (bytesRead === 0) break;
          off += bytesRead;
        }
        const data = buf.subarray(0, off);
        if (data.subarray(0, SNIFF_BYTES).includes(0)) return reply.code(415).send({ error: "binary file" });
        let content: string;
        try {
          content = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(data);
        } catch {
          return reply.code(415).send({ error: "not valid UTF-8 text" }); // saving would corrupt it
        }
        audit("file.read", req, prefix, s.id, loc.rel, data.length);
        return { path: loc.rel, content, sha: sha256(data), mtime: st.mtime.toISOString(), size: data.length };
      } finally {
        await fh.close().catch(() => {});
      }
    });

    app.put(
      `${base}/text`,
      { ...writeLimit, bodyLimit: editCap() * 6 + 4096, errorHandler: tooLarge },
      async (req, reply) => {
        const s = scope(req, reply);
        if (!s) return reply;
        const body = (req.body ?? {}) as { path?: unknown; content?: unknown };
        if (typeof body !== "object" || Array.isArray(body)) return reply.code(400).send({ error: "bad body" });
        const out = await saveText(s.root, body);
        if (out.status === 200) {
          const o = out.body as { path: string; size: number };
          audit("file.write", req, prefix, s.id, o.path, o.size);
        }
        return reply.code(out.status).send(out.body);
      },
    );
  }

  // ---- raw transfer: encapsulated so the root 5 MiB octet-stream parser (attachments.ts) is untouched ----

  void app.register(async (sub) => {
    sub.removeContentTypeParser("application/octet-stream");
    // Hand the handler the unread request stream; it counts and caps the bytes itself.
    sub.addContentTypeParser("application/octet-stream", (_req, payload, done) => done(null, payload));

    for (const prefix of ["projects", "sessions"] as const) {
      const base = `/${prefix}/:id/files/raw`;
      const scope = (req: FastifyRequest, reply: FastifyReply) => {
        const id = (req.params as { id: string }).id;
        const r = rootFor(prefix, id);
        if ("status" in r) {
          void reply.code(r.status).send({ error: r.error });
          return null;
        }
        return { id, root: r.root };
      };

      sub.get(base, rl(30), async (req, reply) => {
        const s = scope(req, reply);
        if (!s) return reply;
        const loc = locateExisting(s.root, (req.query as { path?: unknown }).path);
        if ("status" in loc) return reply.code(loc.status).send({ error: loc.error });
        let fh;
        try {
          fh = await open(loc.real!, "r");
        } catch {
          return reply.code(404).send({ error: "not found" });
        }
        try {
          const st = await fh.stat(); // fstat on the open fd: what we measure is what we stream
          if (!st.isFile()) throw bad(400, "not a file");
          if (st.size > downloadCap()) throw bad(413, "too large to download");
          audit("file.download", req, prefix, s.id, loc.rel, st.size);
          const stream = fh.createReadStream(); // closes the handle when it ends
          return reply
            .header("Content-Type", "application/octet-stream")
            .header("Content-Length", st.size)
            .header("Content-Disposition", contentDisposition(loc.name))
            .header("X-Content-Type-Options", "nosniff")
            .send(stream);
        } catch (e) {
          await fh.close().catch(() => {});
          const b = e as BrowseError;
          if (typeof b?.status === "number") return reply.code(b.status).send({ error: b.error });
          return reply.code(500).send({ error: "could not read the file" });
        }
      });

      sub.put(base, { ...rl(30), bodyLimit: uploadCap() + MiB, errorHandler: tooLarge }, async (req, reply) => {
        const s = scope(req, reply);
        if (!s) return reply;
        const q = req.query as { path?: unknown; overwrite?: unknown };
        if (q.overwrite !== undefined && q.overwrite !== "0" && q.overwrite !== "1") return reply.code(400).send({ error: "overwrite must be 0 or 1" });
        const overwrite = q.overwrite === "1";
        const loc = locate(s.root, q.path);
        if ("status" in loc) {
          // `locate` reports an existing name as a plain 409 only for non-regular/dangling leftovers.
          return reply.code(loc.status).send({ error: loc.error });
        }
        if (loc.real && !overwrite) return reply.code(409).send({ error: "already exists" });

        const max = uploadCap();
        const declared = Number(req.headers["content-length"] ?? 0);
        if (declared > max) {
          audit("file.upload_reject", req, prefix, s.id, loc.rel, declared);
          return reply.header("Connection", "close").code(413).send({ error: "too large" });
        }
        const type = String(req.headers["content-type"] ?? "").split(";")[0].trim().toLowerCase();
        // Any other type is consumed by another parser before we run, and req.raw would never end.
        if (type !== "application/octet-stream" || req.raw.readableEnded) return reply.code(415).send({ error: "send the file as application/octet-stream" });
        const guard = diskGuard(db, loc.dir);
        if (!guard.ok) return reply.code(507).send({ error: guard.message });

        const { tmp, fh } = await makeTemp(loc.dir, loc.name, loc.mode);
        const hash = createHash("sha256");
        let count = 0;
        let overflow = false;
        try {
          // Manual pump, not `for await`: breaking out of an async iterator would destroy the request
          // socket and take the 413 response with it. On overflow we just stop reading.
          await new Promise<void>((resolve, reject) => {
            const src = req.raw;
            src.on("data", (chunk: Buffer) => {
              count += chunk.length;
              if (count > max) {
                overflow = true;
                src.pause();
                src.removeAllListeners("data");
                return resolve();
              }
              hash.update(chunk);
              src.pause();
              fh.write(chunk).then(() => src.resume(), reject);
            });
            src.on("end", resolve);
            src.on("error", reject);
            src.on("close", () => (src.readableEnded ? resolve() : reject(new Error("closed"))));
          });
        } catch {
          await fh.close().catch(() => {});
          await quietUnlink(tmp);
          return reply.code(400).send({ error: "upload interrupted" });
        }
        if (!overflow) {
          try {
            await fh.sync();
            await fh.close();
          } catch {
            await fh.close().catch(() => {});
            await quietUnlink(tmp);
            return reply.code(500).send({ error: "could not write the file" });
          }
        }
        if (overflow) {
          await fh.close().catch(() => {});
          await quietUnlink(tmp);
          audit("file.upload_reject", req, prefix, s.id, loc.rel, count);
          return reply.header("Connection", "close").code(413).send({ error: "too large" });
        }

        const out: Out = await withProjectLock(s.root, async () => {
          try {
            const now = locate(s.root, q.path);
            let target: string;
            if ("status" in now) {
              if (now.status !== 409) return { status: now.status, body: { error: now.error } };
              return { status: 409, body: { error: "already exists" } }; // appeared meanwhile (or a dangling link)
            }
            if (now.dir !== loc.dir) return { status: 409, body: { error: "folder changed during upload" } };
            if (now.real && !overwrite) return { status: 409, body: { error: "already exists" } };
            target = now.real ?? join(now.dir, now.name);
            await publish(tmp, target, loc.dir);
            return { status: 200, body: { path: now.rel, sha: hash.digest("hex"), size: count } };
          } catch {
            return { status: 500, body: { error: "could not write the file" } };
          }
        });
        if (out.status !== 200) await quietUnlink(tmp);
        else audit("file.upload", req, prefix, s.id, (out.body as { path: string }).path, count);
        return reply.code(out.status).send(out.body);
      });
    }
  });
}
