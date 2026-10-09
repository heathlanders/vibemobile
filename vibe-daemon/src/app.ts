// The daemon's HTTP surface (M1). Bearer token required on every route except
// the public allowlist (/health, /pair). buildApp(db) returns a configured
// Fastify instance with no network bind, so tests drive it via app.inject().
// Listening is server.ts's job (localhost only — PLAN §5).

import Fastify, { type FastifyInstance } from "fastify";
import rateLimit from "@fastify/rate-limit";
import websocket from "@fastify/websocket";
import type { DB } from "./db.js";
import { authenticate, pairDevice, logEvent, type Device } from "./auth.js";
import { scanProjects, upsertProjects, projectRoots } from "./scanner.js";
import { realTmux, type Tmux } from "./tmux.js";
import { registerSessionRoutes } from "./sessions.js";
import { registerAttachmentRoutes } from "./attachments.js";
import { registerFileEditRoutes } from "./file-edits.js";
import { registerSessionImageRoute } from "./session-image.js";
import { registerProjectTreeRoute } from "./project-tree.js";
import { registerPtyWs } from "./pty-ws.js";
import { registerSessionWs } from "./session-ws.js";
import { registerPromptRoutes } from "./prompts.js";
import { registerNoteRoutes } from "./notes.js";
import { registerScaffoldRoutes } from "./scaffolds.js";
import { registerProjectCreateRoute } from "./projects.js";
import { registerGitRoutes } from "./git.js";
import { registerRewindRoute } from "./checkpoints.js";
import { registerGitWriteRoutes } from "./git-write.js";
import { registerSettingsRoutes } from "./settings.js";
import { registerForkRoute } from "./fork.js";
import { registerScheduleRoutes } from "./schedule.js";
import { registerCiRoutes } from "./ci.js";
import { registerBrowseRoutes } from "./browse.js";
import { getOrStart } from "./session-ws.js";
import { registerSpendRoutes } from "./spend.js";
import { registerSystemRoutes } from "./system.js";
import { registerPlanUsageRoute } from "./usage.js";
import type { ClaudeRegistry } from "./claude.js";

const PUBLIC = new Set(["/health", "/pair"]);

// Failed-auth limiter (security.md #5, user decision 2026-10-06). Tokens are too
// long to guess, so this only caps noise/abuse from one client: after
// AUTH_MAX_FAILS bad tokens in AUTH_WINDOW_MS, that IP gets 429 until the window
// ends. Keyed by req.ip — the tailnet client's address, see trustProxy below.
const AUTH_MAX_FAILS = 20;
const AUTH_WINDOW_MS = 10 * 60_000;
export function authFailLimiter(max = AUTH_MAX_FAILS, windowMs = AUTH_WINDOW_MS, now = () => Date.now()) {
  const fails = new Map<string, { n: number; since: number }>();
  const current = (ip: string) => {
    const f = fails.get(ip);
    if (f && now() - f.since >= windowMs) fails.delete(ip);
    return fails.get(ip);
  };
  return {
    blocked: (ip: string) => (current(ip)?.n ?? 0) >= max,
    // → true exactly when this failure trips the limit (audit once per window).
    fail(ip: string): boolean {
      const f = current(ip) ?? { n: 0, since: now() };
      f.n++;
      fails.set(ip, f);
      return f.n === max;
    },
  };
}

export async function buildApp(
  db: DB,
  tmux: Tmux = realTmux(),
  registry: ClaudeRegistry = new Map(),
  queryFn?: unknown, // injectable Agent SDK query (tests); default = real SDK
  streamTextFn?: unknown, // injectable Vercel AI SDK streamText (native tests); default = real
): Promise<FastifyInstance> {
  // The daemon binds localhost and `tailscale serve` is the only ingress, so the
  // socket peer is always 127.0.0.1. Trust X-Forwarded-For from loopback ONLY:
  // req.ip becomes the tailnet client's address (the hop tailscale appended),
  // so per-IP limits (/pair, failed auth) are per client, not one shared bucket.
  const app = Fastify({ logger: false, trustProxy: "127.0.0.1" });
  const authLimit = authFailLimiter();
  await app.register(rateLimit, { global: false }); // opt-in per route
  await app.register(websocket);

  // Auth gate: reject anything outside PUBLIC without a valid device token.
  app.addHook("onRequest", async (req, reply) => {
    if (PUBLIC.has(req.routeOptions.url ?? "")) return;
    if (authLimit.blocked(req.ip)) return reply.code(429).send({ error: "too many failed attempts" });
    const device = authenticate(db, req.headers.authorization);
    if (!device) {
      logEvent(db, "auth.reject", null, req.url);
      if (authLimit.fail(req.ip)) logEvent(db, "auth.ratelimit", null, req.ip);
      return reply.code(401).send({ error: "unauthorized" });
    }
    (req as { device?: Device }).device = device;
  });

  app.get("/health", async () => ({ ok: true }));

  // Pairing (security #3): redeem a terminal-printed code for a device token.
  // Rate-limited so the 8-digit code can't be brute-forced over the tunnel.
  app.post(
    "/pair",
    { config: { rateLimit: { max: 5, timeWindow: "1 minute" } } },
    async (req, reply) => {
      const { code, device_name } = (req.body ?? {}) as { code?: string; device_name?: string };
      if (!code || !device_name) return reply.code(400).send({ error: "code and device_name required" });
      const result = pairDevice(db, code, device_name);
      if (!result) {
        logEvent(db, "pair.fail", null, device_name);
        return reply.code(401).send({ error: "invalid or expired code" });
      }
      return reply.code(201).send(result); // { device_id, token } — token shown once
    },
  );

  // Device list for the management screen. `current` marks the caller's own
  // device so the client can warn before revoking the phone it's running on.
  app.get("/devices", async (req) => {
    const me = (req as { device?: Device }).device?.id ?? null;
    const rows = db.prepare("SELECT id, name, paired_at, last_seen FROM devices ORDER BY paired_at").all() as {
      id: string;
    }[];
    return rows.map((r) => ({ ...r, current: r.id === me }));
  });

  // Register the caller's FCM token so it gets session pushes (push.ts, ADR 0013).
  // Only ever the caller's own row; revoking the device drops the token with it.
  app.post("/devices/fcm", async (req, reply) => {
    const me = (req as { device?: Device }).device?.id;
    const { token } = (req.body ?? {}) as { token?: unknown };
    if (!me) return reply.code(401).send({ error: "unauthorized" });
    if (typeof token !== "string" || !token.trim() || token.length > 4096) {
      return reply.code(400).send({ error: "token required" });
    }
    // One phone, one row: a token can't stay on a revoked-then-re-paired device.
    db.prepare("UPDATE devices SET fcm_token = NULL WHERE fcm_token = ? AND id != ?").run(token, me);
    db.prepare("UPDATE devices SET fcm_token = ? WHERE id = ?").run(token, me);
    logEvent(db, "device.fcm", me, "");
    return reply.code(204).send();
  });

  // Audit-log read (security.md #14). Read-only by design: an audit log the
  // client can mutate isn't an audit log, so there is no DELETE/PATCH here.
  // Deliberately NOT itself audited — logging every read of the log would
  // amplify without adding information.
  app.get("/events", async (req) => {
    const { limit, before, kind } = req.query as { limit?: string; before?: string; kind?: string };
    const cap = Math.min(Number(limit) || 100, 200);
    return db
      .prepare(
        `SELECT id, kind, device_id, detail, ts FROM events
          WHERE (:before IS NULL OR ts < :before)
            AND (:kind IS NULL OR kind LIKE :kind || '%')
          ORDER BY ts DESC LIMIT :cap`,
      )
      .all({ before: before ?? null, kind: kind ?? null, cap });
  });

  // Scan the project roots, sync the catalog, return it (auth-gated by the hook
  // above; never add to PUBLIC). Filesystem-only — no shell-out (scanner.ts).
  app.get("/projects", async (req) => {
    const rows = upsertProjects(db, scanProjects(projectRoots()));
    logEvent(db, "projects.scan", (req as { device?: Device }).device?.id ?? null, String(rows.length));
    return rows;
  });

  // Per-device revoke (security #4): delete the row → its token stops resolving.
  app.delete("/devices/:id", async (req, reply) => {
    const { id } = req.params as { id: string };
    const info = db.prepare("DELETE FROM devices WHERE id = ?").run(id);
    if (info.changes === 0) return reply.code(404).send({ error: "not found" });
    logEvent(db, "device.revoked", id, "");
    return reply.code(204).send();
  });

  // Session lifecycle (REST) + attach-only byte/event channels (WS). All behind
  // the auth gate above. tmux + the claude registry are injected so tests can
  // drive REST and the Agent SDK without spawning real subprocesses.
  registerSessionRoutes(app, db, tmux, registry);
  registerScheduleRoutes(app, db, registry, { start: (row) => void getOrStart(registry, db, row, queryFn, streamTextFn) }); // scheduled prompts — /schedules (proposal 44)
  registerForkRoute(app, db, registry); // branch a conversation — POST /sessions/:id/fork (proposal 42)
  registerRewindRoute(app, db, registry); // file rewind — POST /sessions/:id/rewind (ADR 0023)
  registerAttachmentRoutes(app, db); // image upload/fetch — /sessions/:id/attachments, /attachments/:id
  registerFileEditRoutes(app, db); // session file viewer — /sessions/:id/file-edits[/diff], /sessions/:id/file (proposal 20)
  registerProjectTreeRoute(app, db); // @file autocomplete — GET /sessions/:id/tree (ADR 0010, names only)
  registerSessionImageRoute(app, db); // chat image preview — GET /sessions/:id/image (ADR 0021, images only)
  registerPtyWs(app, db, tmux); // terminal bytes — WS /pty/:id
  registerSessionWs(app, db, registry, queryFn, streamTextFn); // claude + native events — WS /session/:id
  registerPromptRoutes(app, db); // prompt library CRUD — /prompts
  registerNoteRoutes(app, db); // project notes/TODOs — /projects/:id/notes, /notes/:id (proposal 31)
  registerScaffoldRoutes(app, db); // foundation templates CRUD — /scaffolds (proposal 17)
  registerProjectCreateRoute(app, db); // POST /projects — new dir + scaffold + git (proposal 17)
  registerGitRoutes(app, db); // GET /projects/:id/git-status — read-only (ADR 0011)
  registerBrowseRoutes(app, db); // read-only file browser — /sessions/:id/browse[/file] (proposal 46)
  registerCiRoutes(app, db); // GET /projects|sessions/:id/ci — read-only PR + CI status (proposal 45)
  registerGitWriteRoutes(app, db); // stage / commit / branch, no push (ADR 0024)
  registerSpendRoutes(app, db); // GET /spend — token/cost ledger aggregates (ADR 0017)
  registerSettingsRoutes(app, db); // GET/PUT /settings — session rules + disk limits (ADR 0026)
  registerSystemRoutes(app, db); // GET /system — read-only box health (ADR 0019)
  registerPlanUsageRoute(app); // GET /usage/plan — Max-plan 5h/weekly meters (ADR 0020)

  return app;
}
