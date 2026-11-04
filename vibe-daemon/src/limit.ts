// Continue after the usage limit resets (proposal 67). Opt-in per session: when a turn is
// rejected by the 5-hour window, the daemon stores one continuation (`continue_at`) on the
// session row and a 30 s tick resumes the session after the reset. Bounded: at most
// MAX_CONTINUES in a row (any user turn resets the count), never for the weekly limit,
// never further than 24 h out. The session's permission mode is never touched.

import type { DB } from "./db.js";
import { logEvent } from "./auth.js";
import type { EngineRegistry } from "./engine.js";
import { notifyDevices, type PushType } from "./push.js";
import { diskGuard } from "./settings.js";
import { maxLive } from "./sessions.js";
import { getOrStart } from "./session-ws.js";
import { runningCliSessions } from "./external.js";

export const MAX_CONTINUES = 3;
export const CONTINUE_PROMPT = "The usage limit has reset. Continue the task where you stopped.";
const MAX_WAIT_MS = 24 * 3_600_000;
const JITTER_MIN_S = 60;
const JITTER_SPAN_S = 120; // 60–180 s after the reset
const TICK_MS = 30_000;

/** Pure decision: when to continue (ISO) for a rate-limit event, or null for "don't". `rand` is in [0,1). */
export function planContinuation(
  info: { status?: string; rateLimitType?: string; resetsAt?: number; overageStatus?: string } | null | undefined,
  row: { continue_after_limit?: number } | null | undefined,
  now: number,
  rand: () => number = Math.random,
): string | null {
  if (!row || row.continue_after_limit !== 1) return null;
  if (info?.status !== "rejected" || info.rateLimitType !== "five_hour") return null;
  if (info.overageStatus === "allowed" || info.overageStatus === "allowed_warning") return null; // extra usage keeps the turn running
  if (typeof info.resetsAt !== "number" || !Number.isFinite(info.resetsAt)) return null;
  const resetMs = info.resetsAt * 1000;
  if (resetMs - now >= MAX_WAIT_MS) return null;
  const jitterMs = (JITTER_MIN_S + Math.floor(rand() * JITTER_SPAN_S)) * 1000;
  return new Date(resetMs + jitterMs).toISOString();
}

export type Deps = {
  now: () => Date;
  /** Start (or reuse) the engine for the row and queue the continue prompt. */
  send: (row: Record<string, unknown>, text: string) => void;
  busy: (sessionId: string) => boolean;
  /** A `claude` CLI is running this transcript (ADR 0012): it owns the session, never start a second writer. */
  external: (claudeSessionId: string | null) => boolean;
  push: (type: PushType, sessionId: string) => void;
};

type Row = { id: string; project_id: string; status: string; continue_count: number; claude_session_id: string | null };

/** One pass over the due continuations. Exported for tests; never throws. */
export function tickContinuations(db: DB, deps: Deps): void {
  const due = db
    .prepare("SELECT * FROM sessions WHERE continue_after_limit = 1 AND continue_at IS NOT NULL AND continue_at <= ?")
    .all(deps.now().toISOString()) as Row[];
  const clear = (id: string) => db.prepare("UPDATE sessions SET continue_at = NULL WHERE id = ?").run(id);
  for (const r of due) {
    try {
      if (r.continue_count >= MAX_CONTINUES) {
        clear(r.id);
        deps.push("limit_gave_up", r.id);
        logEvent(db, "session.limit_gave_up", null, r.id);
      } else if (deps.busy(r.id) || deps.external(r.claude_session_id)) {
        clear(r.id); // the SDK resumed it itself, the user is driving, or a CLI owns the transcript
      } else {
        const project = db.prepare("SELECT path FROM projects WHERE id = ?").get((r as any).project_id) as { path: string } | undefined;
        const live = (db.prepare("SELECT COUNT(*) AS n FROM sessions WHERE kind = 'claude' AND status = 'live'").get() as { n: number }).n;
        if (r.status !== "live" && live >= maxLive("claude")) continue; // retry next tick
        if (project && !diskGuard(db, project.path).ok) continue; // retry next tick
        deps.send(r as unknown as Record<string, unknown>, CONTINUE_PROMPT);
        db.prepare("UPDATE sessions SET continue_count = continue_count + 1, continue_at = NULL WHERE id = ?").run(r.id);
        deps.push("limit_continued", r.id);
        logEvent(db, "session.limit_continued", null, `${r.id}:${r.continue_count + 1}`);
      }
    } catch (e) {
      console.error("[limit] continuation failed", r.id, (e as Error)?.message ?? e);
    }
  }
}

export function startContinuer(db: DB, registry: EngineRegistry, queryFn?: unknown, streamTextFn?: unknown): () => void {
  const deps: Deps = {
    now: () => new Date(),
    send: (row, text) => getOrStart(registry, db, row, queryFn, streamTextFn).pushUser(text),
    busy: (id) => registry.get(id)?.busy?.() === true,
    external: (cid) => cid !== null && runningCliSessions().has(cid),
    push: (type, id) => notifyDevices(db, type, id),
  };
  const tick = () => {
    try {
      tickContinuations(db, deps);
    } catch (e) {
      console.error("[limit] tick failed", (e as Error)?.message ?? e);
    }
  };
  tick();
  const timer = setInterval(tick, TICK_MS);
  timer.unref?.();
  return () => clearInterval(timer);
}
