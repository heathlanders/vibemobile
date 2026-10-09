// Session file viewer (proposal 20, session-rest.md). Reconstructs per-file
// diffs of a session's Edit/Write tool calls from the persisted tool_json rows
// (claude.ts) — DB-only for the list/diff routes; the content route is the only
// filesystem read and is gated as a new read surface (security.md).
//
// Diffs are per-edit sections, never chained: sequential Edits are disjoint
// snippets of an unknown full file, so merging them into one patch would lie.
// Write ops render as all-additions (`written` flag — prior content unknown).
// No silent truncation anywhere: every cut appends a visible marker line and
// sets `truncated: true` (proposal 02 invariant).

import { readFile, realpath, stat } from "node:fs/promises";
import { relative, resolve, isAbsolute } from "node:path";
import type { FastifyInstance } from "fastify";
import type { DB } from "./db.js";
import { logEvent, type Device } from "./auth.js";
import { pathInRoots } from "./paths.js";
// Diff rendering lives in diff-preview.ts — shared with the permission gate, so
// a pre-approval preview and this post-hoc view are the same code (proposal 02).
import { buildEditDiff, type EditOp } from "./diff-preview.js";

export { buildEditDiff };

const MAX_FILE_BYTES = Number(process.env.VIBE_MAX_FILEVIEW_BYTES ?? 512 * 1024);

type ToolJson = {
  name?: string;
  input?: {
    file_path?: string;
    path?: string;
    old_string?: string;
    new_string?: string;
    replace_all?: boolean;
    content?: string;
    edits?: { old_string?: string; new_string?: string; replace_all?: boolean }[];
  };
  isError?: boolean;
};

// Scan a session's tool rows and group successful file-writing ops by path.
// Ops with a missing result are kept (the tool likely ran; the session may have
// died mid-turn); ops with isError are skipped — they didn't change the file.
export function collectFileEdits(db: DB, sessionId: string): Map<string, EditOp[]> {
  const rows = db
    .prepare("SELECT tool_json, ts FROM messages WHERE session_id = ? AND role = 'tool' ORDER BY ts")
    .all(sessionId) as { tool_json: string | null; ts: string }[];
  const byPath = new Map<string, EditOp[]>();
  for (const row of rows) {
    if (!row.tool_json) continue;
    let j: ToolJson;
    try {
      j = JSON.parse(row.tool_json);
    } catch {
      continue;
    }
    if (j.isError === true) continue;
    const name = j.name ?? "";
    if (name !== "Edit" && name !== "Write" && name !== "MultiEdit") continue;
    const path = j.input?.file_path ?? j.input?.path;
    if (!path) continue;
    const ops: EditOp[] = [];
    if (name === "Edit") {
      ops.push({
        ts: row.ts,
        tool: "Edit",
        replaceAll: !!j.input?.replace_all,
        written: false,
        oldStr: j.input?.old_string ?? "",
        newStr: j.input?.new_string ?? "",
      });
    } else if (name === "Write") {
      ops.push({ ts: row.ts, tool: "Write", replaceAll: false, written: true, oldStr: "", newStr: j.input?.content ?? "" });
    } else {
      // MultiEdit (older SDK variants): flatten input.edits[] into Edit ops.
      for (const e of j.input?.edits ?? []) {
        ops.push({
          ts: row.ts,
          tool: "Edit",
          replaceAll: !!e.replace_all,
          written: false,
          oldStr: e.old_string ?? "",
          newStr: e.new_string ?? "",
        });
      }
    }
    if (!ops.length) continue;
    const list = byPath.get(path) ?? [];
    list.push(...ops);
    byPath.set(path, list);
  }
  return byPath;
}

export function registerFileEditRoutes(app: FastifyInstance, db: DB): void {
  const sessionProjectPath = (sessionId: string): string | null | undefined => {
    const row = db
      .prepare("SELECT COALESCE(s.worktree_path, p.path) AS path FROM sessions s LEFT JOIN projects p ON p.id = s.project_id WHERE s.id = ?")
      .get(sessionId) as { path: string | null } | undefined;
    return row === undefined ? undefined : row.path; // undefined = no session
  };

  const relPathFor = (path: string, projectPath: string | null): string => {
    if (!projectPath) return path;
    const rel = relative(resolve(projectPath), resolve(path));
    return rel && !rel.startsWith("..") && isAbsolute(rel) === false ? rel : path;
  };

  // Changed-files list — git-status analog over the session's edit set. DB-only.
  app.get("/sessions/:id/file-edits", async (req, reply) => {
    const { id } = req.params as { id: string };
    const projectPath = sessionProjectPath(id);
    if (projectPath === undefined) return reply.code(404).send({ error: "not found" });
    const byPath = collectFileEdits(db, id);
    const out = [...byPath.entries()].map(([path, ops]) => {
      let adds = 0;
      let dels = 0;
      for (const op of ops) {
        const d = buildEditDiff(op);
        adds += d.adds;
        dels += d.dels;
      }
      return {
        path,
        relPath: relPathFor(path, projectPath),
        edits: ops.length,
        adds,
        dels,
        written: ops.some((o) => o.written),
        lastTs: ops[ops.length - 1].ts,
      };
    });
    out.sort((a, b) => (a.lastTs < b.lastTs ? 1 : -1));
    return out;
  });

  // Per-file diff — one section per edit, ts order. Pure DB lookup, no fs.
  app.get("/sessions/:id/file-edits/diff", async (req, reply) => {
    const { id } = req.params as { id: string };
    const { path } = req.query as { path?: string };
    const projectPath = sessionProjectPath(id);
    if (projectPath === undefined) return reply.code(404).send({ error: "not found" });
    const ops = path ? collectFileEdits(db, id).get(path) : undefined;
    if (!ops) return reply.code(404).send({ error: "no edits for path" });
    return {
      path,
      relPath: relPathFor(path!, projectPath),
      edits: ops.map((op) => {
        const d = buildEditDiff(op);
        return { ts: op.ts, tool: op.tool, replaceAll: op.replaceAll, ...d };
      }),
    };
  });

  // Current file content (the full-file toggle). New read surface over the wire
  // (security.md): the session's edit set is the capability — this is NOT a file
  // browser — then realpath + pathInRoots as defence-in-depth (an approved
  // out-of-root edit is still not readable back), regular files only, size cap,
  // binary sniff, every read audited.
  app.get("/sessions/:id/file", async (req, reply) => {
    const { id } = req.params as { id: string };
    const { path } = req.query as { path?: string };
    const projectPath = sessionProjectPath(id);
    if (projectPath === undefined) return reply.code(404).send({ error: "not found" });
    if (!path || !collectFileEdits(db, id).has(path)) return reply.code(404).send({ error: "no edits for path" });

    let real: string;
    try {
      real = await realpath(path); // resolves symlinks before the scope check
    } catch {
      return reply.code(404).send({ error: "file not found" });
    }
    if (!pathInRoots(real)) return reply.code(403).send({ error: "path out of bounds" });
    const st = await stat(real);
    if (!st.isFile()) return reply.code(404).send({ error: "not a regular file" });

    const buf = await readFile(real);
    const truncated = buf.length > MAX_FILE_BYTES;
    const slice = truncated ? buf.subarray(0, MAX_FILE_BYTES) : buf;
    if (slice.subarray(0, 8192).includes(0)) return reply.code(415).send({ error: "binary file" });

    logEvent(db, "file.read", (req as { device?: Device }).device?.id ?? null, `${id}:${path}`);
    return {
      path,
      relPath: relPathFor(path, projectPath),
      content: slice.toString("utf8"),
      size: st.size,
      truncated,
    };
  });
}
