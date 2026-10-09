// Max-plan usage meter. On a subscription the daemon doesn't pay per token; the
// real constraint is the rolling 5-hour session window + weekly per-model limits.
// Claude Code's own `/usage` reads these from GET /api/oauth/usage on the API host
// (api.anthropic.com), authed with the same `claude login` OAuth token the SDK
// subprocess already runs on. We reuse that credential to surface real meters
// instead of the fictitious API-equivalent dollar cost.
//
// Undocumented endpoint: parse defensively and FAIL SOFT — a shape change or auth
// blip must only blank the meters, never break a session. The claude.ai web
// `/usage` is NOT usable here (Cloudflare managed challenge blocks headless).

import type { FastifyInstance } from "fastify";
import type { DB } from "./db.js";
import { logEvent } from "./auth.js";
import { notifyDevices } from "./push.js";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const USAGE_URL = "https://api.anthropic.com/api/oauth/usage";
// The window figures change slowly; poll gently. A longer TTL also means a
// transient 429 from the usage endpoint is ridden out on the last-good value
// (see getUsage) instead of blanking the meter.
const TTL_MS = 5 * 60_000;
// Live-session rate_limit_events keep the 5h/7d-all figures fresh without the
// endpoint, but don't carry per-model weekly limits — still refetch the full set
// this often while events are holding the cache fresh.
const FULL_TTL_MS = 30 * 60_000;

export type UsageLimit = {
  label: string; // "Session" | "All models" | model display name
  pct: number; // 0..100
  resetsAt: string | null; // ISO 8601
  severity?: string; // "normal" | "warning" | ...
};

export type Usage = {
  session: UsageLimit | null;
  weekly: UsageLimit[];
};

let cache: { at: number; data: Usage } | null = null; // last good value
let lastAttempt = 0; // gate attempts (success OR failure) so a rate-limited endpoint isn't hammered
let lastFetch = 0; // last good endpoint fetch (cache.at may be newer, from an SDK event)

// The OAuth access token the CLI login persists. Read fresh each fetch so a
// token the CLI refreshed on disk is picked up. Never logged, never sent to the
// app. Absent/malformed → null (fail soft).
function readToken(): string | null {
  try {
    const p = path.join(os.homedir(), ".claude", ".credentials.json");
    const j = JSON.parse(fs.readFileSync(p, "utf8"));
    const t = j?.claudeAiOauth?.accessToken;
    return typeof t === "string" && t.length > 0 ? t : null;
  } catch {
    return null;
  }
}

const num = (v: unknown): number => (typeof v === "number" && isFinite(v) ? v : 0);
const iso = (v: unknown): string | null => (typeof v === "string" && v ? v : null);

// Normalize the /api/oauth/usage body. Prefer the structured `limits[]` array
// (carries session, weekly-all, and weekly-scoped-per-model with reset times and
// severity); fall back to the top-level five_hour/seven_day summaries.
export function normalizeUsage(raw: any): Usage {
  const limits: any[] = Array.isArray(raw?.limits) ? raw.limits : [];
  let session: UsageLimit | null = null;
  const weekly: UsageLimit[] = [];

  for (const l of limits) {
    const base = { pct: num(l?.percent), resetsAt: iso(l?.resets_at), severity: l?.severity };
    if (l?.group === "session") {
      session = { label: "Session", ...base };
    } else if (l?.group === "weekly") {
      const label =
        l?.kind === "weekly_scoped" ? (l?.scope?.model?.display_name ?? "Scoped") : "All models";
      weekly.push({ label, ...base });
    }
  }

  if (!session && raw?.five_hour) {
    session = { label: "Session", pct: num(raw.five_hour.utilization), resetsAt: iso(raw.five_hour.resets_at) };
  }
  if (!weekly.length && raw?.seven_day) {
    weekly.push({ label: "All models", pct: num(raw.seven_day.utilization), resetsAt: iso(raw.seven_day.resets_at) });
  }

  return { session, weekly };
}

// Cached, fail-soft usage. Returns null in gateway mode (no Max token upstream)
// or when nothing has ever been fetched successfully. On a transient error the
// last good value is returned so meters don't flicker.
export async function getUsage(now = Date.now()): Promise<Usage | null> {
  if (process.env.VIBE_GATEWAY_URL) return null; // gateway routes to a non-Max upstream
  if (cache && now - cache.at < TTL_MS && now - lastFetch < FULL_TTL_MS) return cache.data; // fresh good value
  // Back off on failure too: at most one fetch per TTL regardless of outcome, so a
  // rate-limited endpoint (429) is never hammered into staying limited. Recovers
  // on its own once the limit clears and the next window opens.
  if (now - lastAttempt < TTL_MS) return cache?.data ?? null;
  lastAttempt = now;

  const token = readToken();
  if (!token) return cache?.data ?? null;

  try {
    const res = await fetch(USAGE_URL, {
      headers: {
        authorization: `Bearer ${token}`,
        "anthropic-beta": "oauth-2025-04-20",
      },
    });
    if (!res.ok) return cache?.data ?? null;
    const data = normalizeUsage(await res.json());
    cache = { at: now, data };
    lastFetch = now;
    return data;
  } catch {
    return cache?.data ?? null;
  }
}

// Fold a live SDK session's `rate_limit_event` into the cache (ADR 0020), so the
// meters move during work without calling the rate-limited endpoint. Real shape
// (SDK 0.3.291, Max plan): `rate_limit_info.unifiedWindows.{five_hour,seven_day}`
// = { utilization: 0..1, resetsAt: epoch seconds } — not in the SDK's .d.ts, so
// parse defensively and ignore anything else. Per-model weekly entries and
// severity are kept from the last endpoint fetch.
export function ingestRateLimit(info: any, now = Date.now()): void {
  if (process.env.VIBE_GATEWAY_URL) return; // gateway sessions aren't on the Max plan
  const win = (x: any) =>
    typeof x?.utilization === "number" && isFinite(x.utilization)
      ? {
          pct: Math.round(x.utilization * 100),
          resetsAt: typeof x.resetsAt === "number" ? new Date(x.resetsAt * 1000).toISOString() : null,
        }
      : null;
  const five = win(info?.unifiedWindows?.five_hour);
  const seven = win(info?.unifiedWindows?.seven_day);
  if (!five && !seven) return;

  const prev = cache?.data ?? { session: null, weekly: [] };
  const session = five ? { ...prev.session, label: "Session", ...five } : prev.session;
  let weekly = prev.weekly;
  if (seven) {
    const i = weekly.findIndex((l) => l.label === "All models");
    const all = { ...weekly[i], label: "All models", ...seven };
    weekly = i < 0 ? [all, ...weekly] : weekly.map((l, j) => (j === i ? all : l));
  }
  cache = { at: now, data: { session, weekly } };
}

// Test hook: forget all cached state.
export function resetUsageCache(): void {
  cache = null;
  lastAttempt = 0;
  lastFetch = 0;
}

// Session-independent read of the same cached meters, for the app's always-on
// sidebar meter. Shares getUsage's cache + backoff, so polling this can't add
// load on the usage endpoint. `fetchedAt` lets the client show staleness when a
// 429 has it riding on the last good value; `usage` null = never fetched.
export function registerPlanUsageRoute(app: FastifyInstance): void {
  app.get("/usage/plan", async () => {
    const usage = await getUsage();
    return { usage, fetchedAt: cache ? new Date(cache.at).toISOString() : null };
  });
}

// "Use it or lose it" nudge (ADR 0020): a window close to its reset with most of
// it unused. Per window: how close to the reset, and the usage ceiling.
const NUDGES = [
  { label: "Session", find: (u: Usage) => u.session, leadMs: 30 * 60_000, maxPct: 50 },
  { label: "All models", find: (u: Usage) => u.weekly.find((l) => l.label === "All models"), leadMs: 12 * 3_600_000, maxPct: 50 },
];

// Windows that qualify now, keyed by label + reset minute. The endpoint and the
// SDK event report the same reset a few hundred ms apart (…:59.67 vs :00), so
// round to the minute or one window would push twice.
export function dueNudges(u: Usage | null, now: number): string[] {
  if (!u) return [];
  const due: string[] = [];
  for (const n of NUDGES) {
    const l = n.find(u);
    const at = l?.resetsAt ? Date.parse(l.resetsAt) : NaN;
    if (!l || !isFinite(at)) continue;
    const left = at - now;
    if (left > 0 && left <= n.leadMs && l.pct < n.maxPct) due.push(`${n.label}@${Math.round(at / 60_000)}`);
  }
  return due;
}

// Background check: one content-free push per window reset (ADR 0013 — the
// phone opens the app to see which). Reads through getUsage's cache/backoff,
// so it adds no endpoint load beyond the TTL. Silent in gateway mode.
export function startUsageNudger(
  db: DB,
  { intervalMs = 5 * 60_000, notify = notifyDevices, usage = getUsage } = {},
): () => void {
  const pushed = new Set<string>();
  const tick = async () => {
    try {
      const fresh = dueNudges(await usage(), Date.now()).filter((k) => !pushed.has(k));
      if (!fresh.length) return;
      for (const k of fresh) pushed.add(k);
      if (pushed.size > 50) pushed.delete(pushed.values().next().value!); // bounded; old resets never recur
      logEvent(db, "usage.nudge", null, fresh.join("; "));
      notify(db, "usage_reset", "");
    } catch {
      /* best-effort; never take the daemon down */
    }
  };
  const timer = setInterval(tick, intervalMs);
  timer.unref?.();
  return () => clearInterval(timer);
}
