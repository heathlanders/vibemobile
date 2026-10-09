// Session lifecycle REST (protocols/session-rest.md). Creation/teardown live on
// REST; the byte channel (WS /pty/:id, pty-ws.ts) is attach-only. Auth is the
// global bearer hook in app.ts (these routes aren't in PUBLIC). tmux is injected
// so REST tests can run against a fake without spawning real tmux.
//
// M2 = kind 'terminal' only. kind 'claude' (Agent SDK) is M3 → 501 here.

import { randomBytes } from "node:crypto";
import type { FastifyInstance } from "fastify";
import type { DB } from "./db.js";
import type { Tmux } from "./tmux.js";
import type { ClaudeRegistry } from "./claude.js";
import { logEvent, type Device } from "./auth.js";
import { pathInRoots } from "./paths.js";
import { listModels } from "./gateway.js";
import { installedPresets, presetById } from "./presets.js";
import { discoverExternalSessions } from "./discover.js";
import { runningCliSessions } from "./external.js";
import { parseMode } from "./engine.js";
import { isNativeProvider, providerFor } from "./gateway.js";
import { createWorktree, removeWorktree, WorktreeError } from "./worktree.js";
import { diskGuard } from "./settings.js";

const nowIso = () => new Date().toISOString();
// Exported for discover.ts, which mints rows for externally-started sessions
// the same way a daemon-created one is minted.
export const newId = () => "s_" + randomBytes(6).toString("hex");

// Concurrency caps for a memory-constrained host. A claude session is a full
// Agent SDK subprocess (≈hundreds of MB resident); terminal is a cheap tmux but
// still bounded. Counted over live rows of the kind — DELETE frees a slot; the
// idle reaper does NOT (an evicted-but-resumable claude session is still a live
// logical session). Read per-request so the unit env can retune without rebuild.
// Claude default raised 4 → 6 to match the multi-chat grid (proposals/19).
export const maxLive = (kind: string): number =>
  kind === "claude" ? Number(process.env.VIBE_MAX_CLAUDE ?? 6) : Number(process.env.VIBE_MAX_TERMINAL ?? 8);

// Isolated worktrees on disk (ADR 0022). Kept ones count until removed by hand.
const maxWorktrees = (): number => Number(process.env.VIBE_MAX_WORKTREES ?? 12);

type SessionRow = {
  id: string;
  project_id: string;
  kind: string;
  title: string | null;
  status: string;
  created_at: string;
  tags: string | null;
  title_auto: number;
  model: string | null;
  claude_session_id: string | null;
};

// Defence-in-depth: only spawn a shell inside an allowed project root, even
// though the scanner only ever inserts in-root paths (security.md #7). The guard
// lives in paths.ts — shared with project creation (projects.ts).

// Live terminal rows whose tmux session is gone read as 'stale' (reattach.md).
async function reconcile(db: DB, tmux: Tmux, row: SessionRow): Promise<SessionRow> {
  if (row.kind === "terminal" && row.status === "live" && !(await tmux.hasSession(row.id))) {
    db.prepare("UPDATE sessions SET status = 'stale' WHERE id = ?").run(row.id);
    return { ...row, status: "stale" };
  }
  return row;
}

export function registerSessionRoutes(app: FastifyInstance, db: DB, tmux: Tmux, registry: ClaudeRegistry): void {
  // Model picker source (ADR 0007). Operator-maintained, non-secret list from the
  // gateway config env — the phone renders it and passes the chosen id on create.
  app.get("/models", async () => ({ models: await listModels() }));

  // Agent CLI presets installed on the box (ADR 0016) — ids + labels only.
  app.get("/presets", async () => ({
    presets: (await installedPresets()).map(({ id, label }) => ({ id, label })),
  }));

  // Create a session. terminal → detached tmux session + row; claude → row only
  // (the Agent SDK starts lazily on WS /session/:id attach — session-rest.md).
  app.post("/sessions", async (req, reply) => {
    const { project_id, kind, title, initialPrompt, model, preset, mode, worktree } = (req.body ?? {}) as {
      project_id?: string;
      kind?: string;
      title?: string;
      initialPrompt?: string;
      model?: string;
      preset?: string;
      mode?: string;
      worktree?: unknown;
    };
    if (!project_id || !kind) return reply.code(400).send({ error: "project_id and kind required" });
    if (kind !== "terminal" && kind !== "claude") {
      return reply.code(400).send({ error: "kind must be 'terminal' or 'claude'" });
    }
    // Initial session mode (proposal 25): whitelisted name, claude sessions only.
    if (mode !== undefined && (kind !== "claude" || !parseMode(mode))) {
      return reply.code(400).send({ error: "mode must be 'ask' | 'auto' | 'plan' (claude sessions only)" });
    }
    // Isolated worktree (ADR 0022): Claude-engine sessions only — native sessions
    // have no write tools, and a terminal is just a shell.
    if (worktree !== undefined && typeof worktree !== "boolean") {
      return reply.code(400).send({ error: "worktree must be a boolean" });
    }
    if (worktree === true && (kind !== "claude" || (typeof model === "string" && isNativeProvider(providerFor(model.trim()))))) {
      return reply.code(400).send({ error: "worktree is only for Claude-engine sessions" });
    }
    // Preset (ADR 0016): an id from the server's table, terminal only, and installed.
    // The command itself never comes from the client.
    let agent: { label: string; command: string } | undefined;
    if (preset !== undefined) {
      const p = typeof preset === "string" ? presetById(preset) : undefined;
      if (kind !== "terminal" || !p) return reply.code(400).send({ error: "unknown preset" });
      if (!(await installedPresets()).some((i) => i.id === p.id)) {
        return reply.code(400).send({ error: `${p.label} is not installed on the server` });
      }
      agent = p;
    }

    const project = db.prepare("SELECT id, path FROM projects WHERE id = ?").get(project_id) as
      | { id: string; path: string }
      | undefined;
    if (!project) return reply.code(404).send({ error: "project not found" });
    if (!pathInRoots(project.path)) return reply.code(400).send({ error: "project path out of bounds" });

    // Reject before spawning anything (tmux / SDK subprocess) once the host is full.
    const live = (
      db.prepare("SELECT COUNT(*) AS n FROM sessions WHERE kind = ? AND status = 'live'").get(kind) as { n: number }
    ).n;
    if (live >= maxLive(kind)) {
      logEvent(db, "session.cap", (req as { device?: Device }).device?.id ?? null, `${kind}:${live}`);
      return reply.code(429).send({ error: `too many live ${kind} sessions (max ${maxLive(kind)})` });
    }

    // Don't start new work on a nearly full disk (setting disk.min_free_gb, ADR 0026).
    const disk = diskGuard(db, project.path);
    if (!disk.ok) {
      logEvent(db, "session.disk_guard", (req as { device?: Device }).device?.id ?? null, `${kind}:${project.path}`);
      return reply.code(507).send({ error: disk.message });
    }

    if (worktree === true) {
      const n = (db.prepare("SELECT COUNT(*) AS n FROM sessions WHERE worktree_path IS NOT NULL").get() as { n: number }).n;
      if (n >= maxWorktrees()) {
        return reply.code(429).send({ error: `too many worktree sessions (max ${maxWorktrees()}) — delete one first` });
      }
    }

    const id = newId();
    const created_at = nowIso();
    let wt: Awaited<ReturnType<typeof createWorktree>> | null = null;
    if (worktree === true) {
      try {
        wt = await createWorktree(project.path, id);
      } catch (e) {
        return reply.code(400).send({ error: e instanceof WorktreeError ? e.message : "could not create the worktree" });
      }
      logEvent(db, "session.worktree.create", (req as { device?: Device }).device?.id ?? null, `${id}:${wt.branch}`);
    }
    if (kind === "terminal") await tmux.createSession(id, project.path, agent?.command); // claude spawns on WS attach
    // initialPrompt (proposal 15): only meaningful for claude — primed as the first
    // turn when the SDK starts on attach, so create-and-prime is atomic (no race).
    const initial = kind === "claude" && typeof initialPrompt === "string" && initialPrompt.trim() ? initialPrompt : null;
    // Model is only meaningful for claude sessions (ADR 0007). Any string is
    // accepted — the gateway rejects unknown ids at runtime (no coupling to /models).
    const sessionModel = kind === "claude" && typeof model === "string" && model.trim() ? model.trim() : null;
    const sessionTitle = title ?? agent?.label ?? null;
    db.prepare(
      "INSERT INTO sessions (id, project_id, kind, title, status, created_at, initial_prompt, model, mode, worktree_path, worktree_branch, base_ref) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
    ).run(id, project_id, kind, sessionTitle, "live", created_at, initial, sessionModel, mode ? parseMode(mode) : null, wt?.path ?? null, wt?.branch ?? null, wt?.baseRef ?? null);
    logEvent(db, "session.create", (req as { device?: Device }).device?.id ?? null, agent ? `${id} preset:${preset}` : id);

    return reply.code(201).send({
      id, project_id, kind, title: sessionTitle, status: "live", created_at, model: sessionModel,
      worktree_branch: wt?.branch ?? null,
    });
  });

  // List sessions (dashboard), optionally by project. Status reconciled so dead
  // ones can be greyed out rather than offered for a doomed attach.
  app.get("/sessions", async (req) => {
    const { project_id } = req.query as { project_id?: string };
    if (project_id) {
      // Pick up any session started outside the daemon (e.g. `claude` CLI over
      // SSH) for this project before listing (discover.ts).
      const project = db.prepare("SELECT id, path FROM projects WHERE id = ?").get(project_id) as
        | { id: string; path: string }
        | undefined;
      if (project) discoverExternalSessions(db, project);
    }
    const rows = (
      project_id
        ? db.prepare("SELECT * FROM sessions WHERE project_id = ? ORDER BY created_at DESC").all(project_id)
        : db.prepare("SELECT * FROM sessions ORDER BY created_at DESC").all()
    ) as SessionRow[];
    // Flag rows a `claude` CLI is running right now (ADR 0012) so the list can
    // badge them; opening one mirrors instead of resuming.
    const running = runningCliSessions();
    return Promise.all(
      rows.map(async (r) => {
        const cli = r.claude_session_id ? running.get(r.claude_session_id) : undefined;
        const row = await reconcile(db, tmux, r);
        return cli ? { ...row, external: { status: cli.status } } : row;
      }),
    );
  });

  app.get("/sessions/:id", async (req, reply) => {
    const { id } = req.params as { id: string };
    const row = db.prepare("SELECT * FROM sessions WHERE id = ?").get(id) as SessionRow | undefined;
    if (!row) return reply.code(404).send({ error: "not found" });
    return reconcile(db, tmux, row);
  });

  // Edit a session's mutable fields: title and/or tags (proposal 12). Only the
  // keys present in the body change. 404 if it doesn't exist.
  app.patch("/sessions/:id", async (req, reply) => {
    const { id } = req.params as { id: string };
    const body = (req.body ?? {}) as { title?: string; tags?: string };
    const sets: string[] = [];
    const vals: (string | null)[] = [];
    if ("title" in body) {
      // A manual rename pins the title: title_auto = 0 stops the auto-titler from
      // ever overwriting it (ADR 0009). Literal, so it takes no `vals` slot.
      sets.push("title = ?", "title_auto = 0");
      vals.push(body.title ?? null);
    }
    if ("tags" in body) {
      // Normalize CSV: trim, drop blanks, dedupe; store null when empty.
      const tags = (body.tags ?? "")
        .split(",")
        .map((t) => t.trim())
        .filter(Boolean);
      sets.push("tags = ?");
      vals.push(tags.length ? [...new Set(tags)].join(",") : null);
    }
    if (!sets.length) return reply.code(400).send({ error: "nothing to update" });
    const info = db.prepare(`UPDATE sessions SET ${sets.join(", ")} WHERE id = ?`).run(...vals, id);
    if (info.changes === 0) return reply.code(404).send({ error: "not found" });
    logEvent(db, "session.rename", (req as { device?: Device }).device?.id ?? null, id);
    return db.prepare("SELECT * FROM sessions WHERE id = ?").get(id);
  });

  // Search a session's transcript (proposal 10). Case-insensitive LIKE over
  // message content; newest first. Returns lightweight rows for a results list.
  app.get("/sessions/:id/messages", async (req, reply) => {
    const { id } = req.params as { id: string };
    const { q } = req.query as { q?: string };
    if (!db.prepare("SELECT 1 FROM sessions WHERE id = ?").get(id)) {
      return reply.code(404).send({ error: "not found" });
    }
    const rows = q
      ? db
          .prepare(
            "SELECT id, role, content, ts FROM messages WHERE session_id = ? AND content LIKE ? ESCAPE '\\' ORDER BY ts DESC LIMIT 100",
          )
          .all(id, `%${q.replace(/[\\%_]/g, (c) => "\\" + c)}%`)
      : db
          .prepare("SELECT id, role, content, ts FROM messages WHERE session_id = ? ORDER BY ts DESC LIMIT 100")
          .all(id);
    return rows;
  });

  // What a push notification renders (ADR 0013): the session's waiting approval
  // requests and questions, as the same frames the WS would have sent. Empty when
  // the session has no running engine (nothing can be waiting).
  app.get("/sessions/:id/pending", async (req, reply) => {
    const { id } = req.params as { id: string };
    const row = db.prepare("SELECT title FROM sessions WHERE id = ?").get(id) as { title: string | null } | undefined;
    if (!row) return reply.code(404).send({ error: "not found" });
    const pending = registry.get(id)?.pending() ?? { permissions: [], dialogs: [] };
    return { title: row.title, ...pending };
  });

  // Answer from a notification action, without a WS attach. Same gate and audit
  // trail as the WS `permission` / `dialog_response` frames (security.md #5);
  // 410 when the request already resolved (answered elsewhere, or timed out).
  app.post("/sessions/:id/permission", async (req, reply) => {
    const { id } = req.params as { id: string };
    const { toolUseID, allow } = (req.body ?? {}) as { toolUseID?: unknown; allow?: unknown };
    if (typeof toolUseID !== "string" || typeof allow !== "boolean") {
      return reply.code(400).send({ error: "toolUseID and allow required" });
    }
    const deviceId = (req as { device?: Device }).device?.id ?? null;
    if (!registry.get(id)?.onPermission(toolUseID, allow, deviceId)) return reply.code(410).send({ error: "no longer pending" });
    return reply.code(204).send();
  });

  app.post("/sessions/:id/dialog", async (req, reply) => {
    const { id } = req.params as { id: string };
    const { dialogId, completed, result } = (req.body ?? {}) as { dialogId?: unknown; completed?: unknown; result?: unknown };
    if (typeof dialogId !== "string" || typeof completed !== "boolean") {
      return reply.code(400).send({ error: "dialogId and completed required" });
    }
    const deviceId = (req as { device?: Device }).device?.id ?? null;
    if (!registry.get(id)?.onDialogResponse(dialogId, completed, result, deviceId)) {
      return reply.code(410).send({ error: "no longer pending" });
    }
    return reply.code(204).send();
  });

  // Bulk-clear stale rows ("clear all stale" in the app). Same effect as DELETE per
  // row: the transcript stays on disk but is dismissed so discovery won't re-list
  // it. Never touches live rows or a session a CLI is running right now.
  app.post("/sessions/prune", async (req, reply) => {
    const { project_id, older_than_days } = (req.body ?? {}) as { project_id?: string; older_than_days?: number };
    if (!project_id) return reply.code(400).send({ error: "project_id required" });
    if (older_than_days !== undefined && !(Number.isFinite(older_than_days) && older_than_days >= 0)) {
      return reply.code(400).send({ error: "older_than_days must be a non-negative number" });
    }
    const cutoff = new Date(Date.now() - (older_than_days ?? 0) * 86_400_000).toISOString();
    const running = runningCliSessions();
    const rows = (
      db
        .prepare(
          "SELECT id, claude_session_id, worktree_path, worktree_branch, base_ref FROM sessions WHERE project_id = ? AND status = 'stale' AND created_at <= ?",
        )
        .all(project_id, cutoff) as {
        id: string;
        claude_session_id: string | null;
        worktree_path: string | null;
        worktree_branch: string | null;
        base_ref: string | null;
      }[]
    ).filter((r) => !(r.claude_session_id && running.has(r.claude_session_id)));
    // Worktree rows: remove the checkout only if nothing would be lost (ADR 0022),
    // same rule as DELETE. A kept one stays on disk; the row still goes.
    const projectPath = (db.prepare("SELECT path FROM projects WHERE id = ?").get(project_id) as { path: string } | undefined)?.path;
    let worktreesKept = 0;
    for (const r of rows) {
      if (!r.worktree_path || !projectPath) continue;
      const res = await removeWorktree(projectPath, {
        path: r.worktree_path,
        branch: r.worktree_branch ?? "",
        baseRef: r.base_ref ?? "",
      });
      if (res.kept) worktreesKept++;
    }
    const dismiss = db.prepare("INSERT OR IGNORE INTO dismissed_transcripts (claude_session_id, dismissed_at) VALUES (?,?)");
    const del = db.prepare("DELETE FROM sessions WHERE id = ?");
    db.transaction(() => {
      for (const r of rows) {
        if (r.claude_session_id) dismiss.run(r.claude_session_id, nowIso());
        del.run(r.id);
      }
    })();
    logEvent(db, "session.prune", (req as { device?: Device }).device?.id ?? null, project_id);
    return worktreesKept ? { deleted: rows.length, worktreesKept } : { deleted: rows.length };
  });

  // Tear down for good (distinct from a WS close, which only detaches).
  // Idempotent: deleting an already-gone session is 204, not 404 (session-rest.md).
  app.delete("/sessions/:id", async (req, reply) => {
    const { id } = req.params as { id: string };
    await tmux.killSession(id); // no-op if it wasn't a terminal
    registry.get(id)?.stop(); // stop the Agent SDK loop if it was a live claude session
    registry.delete(id);
    // Its transcript .jsonl outlives the row, so remember it — else discovery
    // re-lists it on the next GET /sessions (discover.ts).
    const row = db
      .prepare(
        "SELECT s.claude_session_id, s.worktree_path, s.worktree_branch, s.base_ref, p.path AS project_path FROM sessions s LEFT JOIN projects p ON p.id = s.project_id WHERE s.id = ?",
      )
      .get(id) as
      | {
          claude_session_id: string | null;
          worktree_path: string | null;
          worktree_branch: string | null;
          base_ref: string | null;
          project_path: string | null;
        }
      | undefined;
    // The worktree goes only if nothing would be lost (ADR 0022); otherwise it stays
    // on disk and the response says where.
    let kept: { path: string; branch: string | null; reason: string } | null = null;
    if (row?.worktree_path && row.project_path) {
      const r = await removeWorktree(row.project_path, {
        path: row.worktree_path,
        branch: row.worktree_branch ?? "",
        baseRef: row.base_ref ?? "",
      });
      const deviceId = (req as { device?: Device }).device?.id ?? null;
      if (r.kept) {
        kept = { path: row.worktree_path, branch: row.worktree_branch, reason: r.reason };
        logEvent(db, "session.worktree.kept", deviceId, `${id}:${r.reason}`);
      } else {
        logEvent(db, "session.worktree.remove", deviceId, id);
      }
    }
    if (row?.claude_session_id) {
      db.prepare("INSERT OR IGNORE INTO dismissed_transcripts (claude_session_id, dismissed_at) VALUES (?,?)").run(
        row.claude_session_id,
        nowIso(),
      );
    }
    db.prepare("DELETE FROM sessions WHERE id = ?").run(id);
    logEvent(db, "session.delete", (req as { device?: Device }).device?.id ?? null, id);
    if (kept) return reply.code(200).send({ kept: true, ...kept });
    return reply.code(204).send();
  });
}
