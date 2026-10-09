// Token/cost ledger (ADR 0017, roadmap phase 3). Both engines record one row per
// model per completed turn; GET /spend aggregates it for the dashboard. Read-only
// over the wire, bearer-gated like every route; no prompt text is stored here.

import { randomUUID } from "node:crypto";
import { statSync } from "node:fs";
import { join } from "node:path";
import type { FastifyInstance } from "fastify";
import type { DB } from "./db.js";

export type UsageRow = {
  sessionId: string;
  provider: string;
  model: string;
  input: number;
  output: number;
  cacheRead?: number;
  cacheWrite?: number;
  cost: number;
};

const n = (v: unknown) => (typeof v === "number" && Number.isFinite(v) && v > 0 ? v : 0);

export function recordUsage(db: DB, u: UsageRow): void {
  const project = db.prepare("SELECT project_id FROM sessions WHERE id = ?").get(u.sessionId) as
    | { project_id: string }
    | undefined;
  db.prepare(
    `INSERT INTO usage_events (id, session_id, project_id, provider, model, input_tokens, output_tokens,
       cache_read, cache_write, cost_usd, ts) VALUES (?,?,?,?,?,?,?,?,?,?,?)`,
  ).run(
    randomUUID(),
    u.sessionId,
    project?.project_id ?? null,
    u.provider,
    u.model,
    n(u.input),
    n(u.output),
    n(u.cacheRead),
    n(u.cacheWrite),
    n(u.cost),
    new Date().toISOString(),
  );
}

// ---- cumulative → delta ---------------------------------------------------------------------------
//
// The Agent SDK reports modelUsage / total_cost_usd as running totals for the WHOLE conversation
// (and keeps counting after a resume in a new process). Recording them per turn as if they were
// per-turn figures summed them again and again — the ledger and sessions.total_cost_usd read ~45x
// too high. recordCumulative stores the new reading as the baseline and records only the increase.
// A reading BELOW the baseline records nothing (and becomes the new baseline): undercounting a
// one-off blip is far safer than re-recording a whole conversation.

type Counters = { input: number; output: number; cacheRead: number; cacheWrite: number; cost: number };
const FIELDS = ["input", "output", "cacheRead", "cacheWrite", "cost"] as const;
const ZERO: Counters = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0 };

/** cur - prev per field, never negative. Pure → unit-tested. */
export function counterDelta(prev: Counters, cur: Counters): Counters {
  const d = { ...ZERO };
  for (const k of FIELDS) d[k] = cur[k] >= prev[k] ? cur[k] - prev[k] : 0;
  return d;
}

const readBaseline = (db: DB, sessionId: string, model: string): Counters => {
  const r = db.prepare("SELECT input_tokens i, output_tokens o, cache_read cr, cache_write cw, cost_usd c FROM usage_cumulative WHERE session_id = ? AND model = ?").get(sessionId, model) as
    | { i: number; o: number; cr: number; cw: number; c: number }
    | undefined;
  return r ? { input: r.i, output: r.o, cacheRead: r.cr, cacheWrite: r.cw, cost: r.c } : { ...ZERO };
};
const writeBaseline = (db: DB, sessionId: string, model: string, c: Counters): void => {
  db.prepare(
    `INSERT INTO usage_cumulative (session_id, model, input_tokens, output_tokens, cache_read, cache_write, cost_usd) VALUES (?,?,?,?,?,?,?)
     ON CONFLICT(session_id, model) DO UPDATE SET input_tokens = excluded.input_tokens, output_tokens = excluded.output_tokens,
       cache_read = excluded.cache_read, cache_write = excluded.cache_write, cost_usd = excluded.cost_usd`,
  ).run(sessionId, model, c.input, c.output, c.cacheRead, c.cacheWrite, c.cost);
};

/** Record one model's CUMULATIVE reading as a per-turn delta. Returns the delta (cost included). */
export function recordCumulative(db: DB, u: UsageRow): Counters {
  const cur: Counters = { input: n(u.input), output: n(u.output), cacheRead: n(u.cacheRead), cacheWrite: n(u.cacheWrite), cost: n(u.cost) };
  const delta = counterDelta(readBaseline(db, u.sessionId, u.model), cur);
  writeBaseline(db, u.sessionId, u.model, cur);
  if (FIELDS.some((k) => delta[k] > 0)) {
    recordUsage(db, { sessionId: u.sessionId, provider: u.provider, model: u.model, input: delta.input, output: delta.output, cacheRead: delta.cacheRead, cacheWrite: delta.cacheWrite, cost: delta.cost });
  }
  return delta;
}

/** A session's cumulative total cost (result.total_cost_usd) → this turn's cost. */
export function cumulativeCostDelta(db: DB, sessionId: string, totalCost: number): number {
  const cur: Counters = { ...ZERO, cost: n(totalCost) };
  const d = counterDelta(readBaseline(db, sessionId, "__total__"), cur);
  writeBaseline(db, sessionId, "__total__", cur);
  return d.cost;
}

/**
 * One-time repair of a ledger written before this fix: rows were cumulative readings summed per turn.
 * Rewrite each (session, model) series as deltas and seed the baselines; recompute each session's
 * total cost from the repaired ledger. The original rows are kept in usage_events_cumulative_backup
 * (its existence is also the "already done" marker). Only provider='anthropic' rows were affected —
 * the native engine always recorded per-turn figures.
 */
export function migrateLedgerToDeltas(db: DB): { rewritten: number } | null {
  if (db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'usage_events_cumulative_backup'").get()) return null;
  let rewritten = 0;
  db.transaction(() => {
    db.exec("CREATE TABLE usage_events_cumulative_backup AS SELECT * FROM usage_events");
    const rows = db
      .prepare(
        "SELECT rowid AS rid, session_id, model, input_tokens, output_tokens, cache_read, cache_write, cost_usd FROM usage_events WHERE provider = 'anthropic' AND session_id IS NOT NULL ORDER BY session_id, model, ts, rowid",
      )
      .all() as { rid: number; session_id: string; model: string; input_tokens: number; output_tokens: number; cache_read: number; cache_write: number; cost_usd: number }[];
    const upd = db.prepare("UPDATE usage_events SET input_tokens = ?, output_tokens = ?, cache_read = ?, cache_write = ?, cost_usd = ? WHERE rowid = ?");
    let prev: Counters = { ...ZERO };
    let key = "";
    const totals = new Map<string, number>(); // session → sum of last cumulative cost per model
    for (const r of rows) {
      const k = `${r.session_id}\u0000${r.model}`;
      if (k !== key) {
        if (key) {
          const [sid, model] = key.split("\u0000");
          writeBaseline(db, sid, model, prev);
          totals.set(sid, (totals.get(sid) ?? 0) + prev.cost);
        }
        key = k;
        prev = { ...ZERO };
      }
      const cur: Counters = { input: r.input_tokens, output: r.output_tokens, cacheRead: r.cache_read, cacheWrite: r.cache_write, cost: r.cost_usd };
      const d = counterDelta(prev, cur);
      upd.run(d.input, d.output, d.cacheRead, d.cacheWrite, d.cost, r.rid);
      prev = cur;
      rewritten++;
    }
    if (key) {
      const [sid, model] = key.split("\u0000");
      writeBaseline(db, sid, model, prev);
      totals.set(sid, (totals.get(sid) ?? 0) + prev.cost);
    }
    for (const [sid, total] of totals) {
      writeBaseline(db, sid, "__total__", { ...ZERO, cost: total });
      db.prepare("UPDATE sessions SET total_cost_usd = ? WHERE id = ? AND kind = 'claude'").run(total, sid);
    }
  })();
  return { rewritten };
}

// Group key → SQL expression. A fixed allowlist: the query param picks an entry,
// it is never interpolated.
const GROUPS: Record<string, string> = {
  project: "COALESCE(u.project_id, '')",
  model: "u.model",
  provider: "u.provider",
  day: "substr(u.ts, 1, 10)",
};

const SUMS = `COUNT(*) AS turns, SUM(input_tokens) AS input, SUM(output_tokens) AS output,
  SUM(cache_read) AS cacheRead, SUM(cache_write) AS cacheWrite, SUM(cost_usd) AS cost`;

// Size of a project's root CLAUDE.md (loaded into every turn's context), or null
// when there is none. Feeds the client's CLAUDE.md-size saving tip (ADR 0017).
function claudeMdBytes(projectPath: string | null): number | null {
  if (!projectPath) return null;
  try {
    const st = statSync(join(projectPath, "CLAUDE.md"));
    return st.isFile() ? st.size : null;
  } catch {
    return null;
  }
}

export function registerSpendRoutes(app: FastifyInstance, db: DB): void {
  // GET /spend?group=project|model|provider|day&days=30 → totals + one row per group.
  app.get("/spend", async (req, reply) => {
    const q = req.query as { group?: string; days?: string };
    const group = q.group ?? "model";
    const expr = GROUPS[group];
    if (!expr) return reply.code(400).send({ error: "group must be project, model, provider or day" });
    const days = Math.min(Math.max(Number(q.days ?? 30) || 30, 1), 365);
    const since = new Date(Date.now() - days * 86_400_000).toISOString();

    let rows = db
      .prepare(
        `SELECT ${expr} AS key, ${group === "project" ? "p.name AS label, p.path AS path" : "NULL AS label"}, ${SUMS}
         FROM usage_events u ${group === "project" ? "LEFT JOIN projects p ON p.id = u.project_id" : ""}
         WHERE u.ts >= ? GROUP BY key ORDER BY ${group === "day" ? "key" : "cost DESC, turns DESC"}`,
      )
      .all(since) as Record<string, unknown>[];
    // Project rows carry their CLAUDE.md size instead of the absolute path.
    if (group === "project") rows = rows.map(({ path, ...r }) => ({ ...r, claudeMdBytes: claudeMdBytes(path as string | null) }));
    const totals = db.prepare(`SELECT ${SUMS} FROM usage_events WHERE ts >= ?`).get(since) as Record<string, number | null>;
    // SUM over zero rows is NULL → report zeros.
    for (const k of Object.keys(totals)) totals[k] ??= 0;
    return { group, days, since, totals, rows };
  });

  // GET /spend/session/:id → one session's all-time totals + one row per model
  // (the chat header's token detail). Unknown id → zero totals, no rows.
  app.get("/spend/session/:id", async (req) => {
    const { id } = req.params as { id: string };
    const rows = db
      .prepare(
        `SELECT model AS key, NULL AS label, ${SUMS} FROM usage_events WHERE session_id = ?
         GROUP BY key ORDER BY cost DESC, turns DESC`,
      )
      .all(id);
    const totals = db.prepare(`SELECT ${SUMS} FROM usage_events WHERE session_id = ?`).get(id) as Record<string, number | null>;
    for (const k of Object.keys(totals)) totals[k] ??= 0;
    return { totals, rows };
  });
}
