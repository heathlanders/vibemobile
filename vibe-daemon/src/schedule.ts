// Scheduled prompts (proposal 44): "every weekday at 09:00, run this prompt in that project".
//
// An UNATTENDED run is the riskiest thing the daemon can be asked to do, so it is bounded:
//   - the run is an ordinary session (same permission gate, file scope, audit, push). The
//     default mode is `ask`, so every tool call waits for the phone — nothing executes by
//     itself unless the user chose `auto` for that schedule on purpose;
//   - at most one run of a schedule at a time (a still-running previous run skips the slot);
//   - the live-session cap and the free-space guard apply exactly as for POST /sessions;
//   - a run missed by more than MISSED_AFTER_MS (daemon was down) is recorded as missed, never
//     fired late and unexpectedly;
//   - every create / change / delete / run is audited; limits on count and text sizes.
// Times are SERVER-local (the API reports the zone) — the phone may be elsewhere.

import { randomBytes } from "node:crypto";
import type { FastifyInstance } from "fastify";
import type { DB } from "./db.js";
import { logEvent, type Device } from "./auth.js";
import type { EngineRegistry } from "./engine.js";
import { parseMode } from "./engine.js";
import { pathInRoots } from "./paths.js";
import { diskGuard } from "./settings.js";
import { maxLive } from "./sessions.js";
import { getOrStart } from "./session-ws.js";

export const MAX_SCHEDULES = 50;
export const MAX_TITLE = 120;
export const MAX_PROMPT = 8000;
export const MISSED_AFTER_MS = 2 * 3_600_000;
const TICK_MS = 30_000;

export type Spec = { kind: "once"; runAt: string } | { kind: "daily"; time: string; days: number[] | null };

// ---- pure scheduling -------------------------------------------------------------------------

/** First run strictly after `after`, in server-local time; null if there is none (a past 'once'). */
export function nextRunAfter(spec: Spec, after: Date): Date | null {
  if (spec.kind === "once") {
    const at = new Date(spec.runAt);
    return Number.isFinite(at.getTime()) && at > after ? at : null;
  }
  const [h, m] = spec.time.split(":").map(Number);
  for (let i = 0; i <= 7; i++) {
    const c = new Date(after);
    c.setDate(c.getDate() + i);
    c.setHours(h, m, 0, 0);
    if (c > after && (spec.days === null || spec.days.includes(c.getDay()))) return c;
  }
  return null; // unreachable for a non-empty days list
}

const TIME = /^([01]\d|2[0-3]):[0-5]\d$/;

type Fields = {
  title?: string; prompt?: string; mode?: string; model?: string | null;
  kind?: "once" | "daily"; time?: string | null; days?: number[] | null; runAt?: string | null; enabled?: boolean;
};

/** Validate a create/patch body. Unknown keys are rejected; nothing is coerced. */
export function validateFields(body: unknown, partial: boolean): { ok: true; v: Fields } | { ok: false; error: string } {
  if (typeof body !== "object" || body === null || Array.isArray(body)) return { ok: false, error: "body must be an object" };
  const b = body as Record<string, unknown>;
  const allowed = ["projectId", "title", "prompt", "mode", "model", "kind", "time", "days", "runAt", "enabled"];
  for (const k of Object.keys(b)) if (!allowed.includes(k)) return { ok: false, error: `${k}: unknown field` };
  const v: Fields = {};
  const need = (k: string) => !partial && !(k in b) && { ok: false as const, error: `${k} is required` };
  for (const k of ["title", "prompt", "kind"]) { const r = need(k); if (r) return r; }

  if ("title" in b) {
    if (typeof b.title !== "string" || !b.title.trim() || b.title.length > MAX_TITLE) return { ok: false, error: `title: 1-${MAX_TITLE} characters` };
    v.title = b.title.trim();
  }
  if ("prompt" in b) {
    if (typeof b.prompt !== "string" || !b.prompt.trim() || b.prompt.length > MAX_PROMPT || b.prompt.includes("\0")) return { ok: false, error: `prompt: 1-${MAX_PROMPT} characters, no NUL` };
    v.prompt = b.prompt;
  }
  if ("mode" in b) {
    if (!parseMode(b.mode)) return { ok: false, error: "mode: ask | auto | plan" };
    v.mode = b.mode as string;
  }
  if ("model" in b) {
    if (b.model !== null && (typeof b.model !== "string" || !b.model.trim() || b.model.length > 128 || /[\s\u0000-\u001f]/.test(b.model))) return { ok: false, error: "model: a model id or null" };
    v.model = b.model as string | null;
  }
  if ("kind" in b) {
    if (b.kind !== "once" && b.kind !== "daily") return { ok: false, error: "kind: once | daily" };
    v.kind = b.kind;
  }
  if ("time" in b) {
    if (b.time !== null && (typeof b.time !== "string" || !TIME.test(b.time))) return { ok: false, error: "time: HH:MM (24 h)" };
    v.time = b.time as string | null;
  }
  if ("days" in b) {
    const d = b.days;
    if (d !== null && (!Array.isArray(d) || d.length === 0 || d.length > 7 || !d.every((x) => Number.isInteger(x) && x >= 0 && x <= 6) || new Set(d).size !== d.length)) {
      return { ok: false, error: "days: null (every day) or distinct numbers 0-6 (Sunday = 0)" };
    }
    v.days = d === null ? null : [...(d as number[])].sort();
  }
  if ("runAt" in b) {
    if (b.runAt !== null && (typeof b.runAt !== "string" || !Number.isFinite(new Date(b.runAt).getTime()))) return { ok: false, error: "runAt: an ISO date-time" };
    v.runAt = b.runAt === null ? null : new Date(b.runAt as string).toISOString();
  }
  if ("enabled" in b) {
    if (typeof b.enabled !== "boolean") return { ok: false, error: "enabled: true or false" };
    v.enabled = b.enabled;
  }
  return { ok: true, v };
}

// ---- rows ---------------------------------------------------------------------------------------

type Row = {
  id: string; project_id: string; title: string; prompt: string; mode: string; model: string | null; kind: "once" | "daily";
  time: string | null; days: string | null; run_at: string | null; enabled: number; next_run_at: string | null;
  last_run_at: string | null; last_status: string | null; last_session_id: string | null; created_at: string;
};

const specOf = (r: Pick<Row, "kind" | "time" | "days" | "run_at">): Spec | null => {
  if (r.kind === "once") return r.run_at ? { kind: "once", runAt: r.run_at } : null;
  return r.time ? { kind: "daily", time: r.time, days: r.days ? r.days.split(",").map(Number) : null } : null;
};

const view = (db: DB, r: Row) => ({
  id: r.id, projectId: r.project_id,
  projectName: (db.prepare("SELECT name FROM projects WHERE id = ?").get(r.project_id) as { name: string } | undefined)?.name ?? null,
  title: r.title, prompt: r.prompt, mode: r.mode, model: r.model, kind: r.kind, time: r.time,
  days: r.days ? r.days.split(",").map(Number) : null, runAt: r.run_at, enabled: r.enabled === 1,
  nextRunAt: r.next_run_at, lastRunAt: r.last_run_at, lastStatus: r.last_status, lastSessionId: r.last_session_id,
});

// ---- running one -----------------------------------------------------------------------------

export type Deps = {
  now: () => Date;
  /** Start the engine for a freshly created session row (default: the real getOrStart). */
  start: (row: Record<string, unknown>) => void;
  /** Is this session mid-turn right now? */
  busy: (sessionId: string) => boolean;
};

export type Launch = { ok: true; sessionId: string } | { ok: false; status: string; retry: boolean };

export function launch(db: DB, s: Row, deps: Deps, deviceId: string | null = null): Launch {
  const project = db.prepare("SELECT path FROM projects WHERE id = ?").get(s.project_id) as { path: string } | undefined;
  if (!project) return { ok: false, status: "failed: project is gone", retry: false };
  if (!pathInRoots(project.path)) return { ok: false, status: "failed: project outside the allowed folders", retry: false };
  if (s.last_session_id && deps.busy(s.last_session_id)) return { ok: false, status: "skipped: the previous run is still going", retry: false };
  const live = (db.prepare("SELECT COUNT(*) AS n FROM sessions WHERE kind = 'claude' AND status = 'live'").get() as { n: number }).n;
  if (live >= maxLive("claude")) return { ok: false, status: "waiting: too many live sessions", retry: true };
  const disk = diskGuard(db, project.path);
  if (!disk.ok) return { ok: false, status: "waiting: low disk space", retry: true };

  const id = "s_" + randomBytes(6).toString("hex");
  const created = deps.now().toISOString();
  db.prepare(
    "INSERT INTO sessions (id, project_id, kind, title, status, created_at, initial_prompt, model, mode) VALUES (?,?,?,?,?,?,?,?,?)",
  ).run(id, s.project_id, "claude", `⏰ ${s.title}`.slice(0, 120), "live", created, s.prompt, s.model, s.mode);
  try {
    deps.start(db.prepare("SELECT * FROM sessions WHERE id = ?").get(id) as Record<string, unknown>);
  } catch (e) {
    db.prepare("DELETE FROM sessions WHERE id = ?").run(id);
    return { ok: false, status: `failed: ${String((e as Error)?.message ?? e).slice(0, 80)}`, retry: false };
  }
  logEvent(db, "schedule.run", deviceId, `${s.id}:${id}:${s.mode}`);
  return { ok: true, sessionId: id };
}

/** One scheduler pass: run what is due, record the outcome, move next_run_at on. Exported for tests. */
export function tickSchedules(db: DB, deps: Deps): void {
  const now = deps.now();
  const due = db.prepare("SELECT * FROM schedules WHERE enabled = 1 AND next_run_at IS NOT NULL AND next_run_at <= ? ORDER BY next_run_at").all(now.toISOString()) as Row[];
  for (const s of due) {
    const late = now.getTime() - new Date(s.next_run_at!).getTime();
    const spec = specOf(s);
    let status: string;
    let sessionId: string | null = s.last_session_id;
    let ranAt: string | null = s.last_run_at;
    let advance = true;
    if (late > MISSED_AFTER_MS) {
      status = "missed";
      logEvent(db, "schedule.missed", null, s.id);
    } else {
      const r = launch(db, s, deps);
      if (r.ok) {
        status = "started";
        sessionId = r.sessionId;
        ranAt = now.toISOString();
      } else {
        status = r.status;
        advance = !r.retry; // waiting → try again next tick (until it is "missed")
        if (!r.retry) logEvent(db, "schedule.skipped", null, `${s.id}:${r.status}`);
      }
    }
    if (advance) {
      const next = spec ? nextRunAfter(spec, now) : null;
      db.prepare("UPDATE schedules SET next_run_at = ?, enabled = ?, last_status = ?, last_session_id = ?, last_run_at = ? WHERE id = ?").run(
        next ? next.toISOString() : null, next ? 1 : 0, status, sessionId, ranAt, s.id);
    } else {
      db.prepare("UPDATE schedules SET last_status = ? WHERE id = ?").run(status, s.id);
    }
  }
}

export function startScheduler(db: DB, registry: EngineRegistry, queryFn?: unknown, streamTextFn?: unknown): () => void {
  const deps: Deps = {
    now: () => new Date(),
    start: (row) => void getOrStart(registry, db, row, queryFn, streamTextFn),
    busy: (id) => registry.get(id)?.busy?.() === true,
  };
  const tick = () => {
    try {
      tickSchedules(db, deps);
    } catch {
      /* a scheduler hiccup must never take the daemon down */
    }
  };
  tick();
  const timer = setInterval(tick, TICK_MS);
  timer.unref?.();
  return () => clearInterval(timer);
}

// ---- routes ---------------------------------------------------------------------------------------

export function registerScheduleRoutes(app: FastifyInstance, db: DB, registry: EngineRegistry, startDeps?: Partial<Deps>): void {
  const limit = { config: { rateLimit: { max: 30, timeWindow: "1 minute" } } };
  const dev = (req: unknown) => (req as { device?: Device }).device?.id ?? null;
  const deps = (): Deps => ({
    now: () => new Date(),
    start: (row) => void getOrStart(registry, db, row, undefined, undefined),
    busy: (id) => registry.get(id)?.busy?.() === true,
    ...startDeps,
  });
  const get = (id: string) => db.prepare("SELECT * FROM schedules WHERE id = ?").get(id) as Row | undefined;
  const tz = () => Intl.DateTimeFormat().resolvedOptions().timeZone;

  app.get("/schedules", async () => ({
    tz: tz(), offsetMin: -new Date().getTimezoneOffset(), now: new Date().toISOString(),
    schedules: (db.prepare("SELECT * FROM schedules ORDER BY created_at DESC").all() as Row[]).map((r) => view(db, r)),
  }));

  // The shape a stored/updated row must have: daily needs a time, once needs a future instant.
  const checkSpec = (r: Pick<Row, "kind" | "time" | "run_at" | "days">, now: Date): string | null => {
    if (r.kind === "daily" && !r.time) return "time is required for a daily schedule";
    if (r.kind === "once") {
      if (!r.run_at) return "runAt is required for a one-time schedule";
      if (new Date(r.run_at) <= now) return "runAt must be in the future";
    }
    return null;
  };

  app.post("/schedules", limit, async (req, reply) => {
    const body = (req.body ?? {}) as Record<string, unknown>;
    const projectId = body.projectId;
    if (typeof projectId !== "string") return reply.code(400).send({ error: "projectId is required" });
    const { projectId: _p, ...rest } = body;
    const val = validateFields(rest, false);
    if (!val.ok) return reply.code(400).send({ error: val.error });
    const project = db.prepare("SELECT path FROM projects WHERE id = ?").get(projectId) as { path: string } | undefined;
    if (!project) return reply.code(404).send({ error: "project not found" });
    if (!pathInRoots(project.path)) return reply.code(403).send({ error: "path out of bounds" });
    if ((db.prepare("SELECT COUNT(*) AS n FROM schedules").get() as { n: number }).n >= MAX_SCHEDULES) return reply.code(429).send({ error: `at most ${MAX_SCHEDULES} schedules` });
    const v = val.v;
    const row: Row = {
      id: "sch_" + randomBytes(5).toString("hex"), project_id: projectId, title: v.title!, prompt: v.prompt!, mode: v.mode ?? "ask",
      model: v.model ?? null, kind: v.kind!, time: v.time ?? null, days: v.days ? v.days.join(",") : null, run_at: v.runAt ?? null,
      enabled: v.enabled === false ? 0 : 1, next_run_at: null, last_run_at: null, last_status: null, last_session_id: null, created_at: new Date().toISOString(),
    };
    const bad = checkSpec(row, new Date());
    if (bad) return reply.code(400).send({ error: bad });
    const next = row.enabled ? nextRunAfter(specOf(row)!, new Date()) : null;
    row.next_run_at = next ? next.toISOString() : null;
    db.prepare(
      "INSERT INTO schedules (id, project_id, title, prompt, mode, model, kind, time, days, run_at, enabled, next_run_at, created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
    ).run(row.id, row.project_id, row.title, row.prompt, row.mode, row.model, row.kind, row.time, row.days, row.run_at, row.enabled, row.next_run_at, row.created_at);
    logEvent(db, "schedule.create", dev(req), `${row.id}:${row.kind}:${row.mode}`);
    return reply.code(201).send(view(db, row));
  });

  app.patch("/schedules/:id", limit, async (req, reply) => {
    const s = get((req.params as { id: string }).id);
    if (!s) return reply.code(404).send({ error: "not found" });
    const val = validateFields(req.body ?? {}, true);
    if (!val.ok) return reply.code(400).send({ error: val.error });
    const v = val.v;
    if (Object.keys(v).length === 0) return reply.code(400).send({ error: "nothing to update" });
    const next: Row = {
      ...s, title: v.title ?? s.title, prompt: v.prompt ?? s.prompt, mode: v.mode ?? s.mode,
      model: "model" in v ? (v.model ?? null) : s.model, kind: v.kind ?? s.kind,
      time: "time" in v ? (v.time ?? null) : s.time, days: "days" in v ? (v.days ? v.days.join(",") : null) : s.days,
      run_at: "runAt" in v ? (v.runAt ?? null) : s.run_at, enabled: v.enabled === undefined ? s.enabled : v.enabled ? 1 : 0,
    };
    const timingChanged = ["kind", "time", "days", "runAt", "enabled"].some((k) => k in v);
    if (next.enabled === 1) {
      const bad = checkSpec(next, new Date());
      if (bad) return reply.code(400).send({ error: bad });
    }
    if (timingChanged) {
      const n = next.enabled ? nextRunAfter(specOf(next)!, new Date()) : null;
      next.next_run_at = n ? n.toISOString() : null;
    }
    db.prepare("UPDATE schedules SET title=?, prompt=?, mode=?, model=?, kind=?, time=?, days=?, run_at=?, enabled=?, next_run_at=? WHERE id=?").run(
      next.title, next.prompt, next.mode, next.model, next.kind, next.time, next.days, next.run_at, next.enabled, next.next_run_at, s.id);
    logEvent(db, "schedule.update", dev(req), `${s.id}:${Object.keys(v).join(",")}`);
    return view(db, get(s.id)!);
  });

  app.delete("/schedules/:id", limit, async (req, reply) => {
    const id = (req.params as { id: string }).id;
    if (db.prepare("DELETE FROM schedules WHERE id = ?").run(id).changes) logEvent(db, "schedule.delete", dev(req), id);
    return reply.code(204).send(); // idempotent
  });

  // Run now, outside the timetable. Does not move next_run_at.
  app.post("/schedules/:id/run", { config: { rateLimit: { max: 6, timeWindow: "1 minute" } } }, async (req, reply) => {
    const s = get((req.params as { id: string }).id);
    if (!s) return reply.code(404).send({ error: "not found" });
    const r = launch(db, s, deps(), dev(req));
    if (!r.ok) return reply.code(r.retry ? 429 : 409).send({ error: r.status.replace(/^[a-z]+: /, "") });
    db.prepare("UPDATE schedules SET last_run_at = ?, last_status = 'started', last_session_id = ? WHERE id = ?").run(new Date().toISOString(), r.sessionId, s.id);
    return reply.code(201).send({ sessionId: r.sessionId });
  });
}
