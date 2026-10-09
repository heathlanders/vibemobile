import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { dueNudges, getUsage, ingestRateLimit, normalizeUsage, resetUsageCache, startUsageNudger } from "./usage.js";

// Captured from a real GET /api/oauth/usage on a Max 5x plan.
const SAMPLE = {
  five_hour: { utilization: 45.0, resets_at: "2026-07-19T18:39:59.707096+00:00" },
  seven_day: { utilization: 3.0, resets_at: "2026-07-26T13:59:59.707115+00:00" },
  limits: [
    { kind: "session", group: "session", percent: 45, severity: "normal", resets_at: "2026-07-19T18:39:59.707096+00:00", scope: null, is_active: true },
    { kind: "weekly_all", group: "weekly", percent: 3, severity: "normal", resets_at: "2026-07-26T13:59:59.707115+00:00", scope: null, is_active: false },
    { kind: "weekly_scoped", group: "weekly", percent: 3, severity: "normal", resets_at: "2026-07-26T13:59:59.707386+00:00", scope: { model: { id: null, display_name: "Fable" }, surface: null }, is_active: false },
  ],
};

test("normalizeUsage maps the limits[] array (session + weekly-all + per-model)", () => {
  const u = normalizeUsage(SAMPLE);
  assert.deepEqual(u.session, {
    label: "Session",
    pct: 45,
    resetsAt: "2026-07-19T18:39:59.707096+00:00",
    severity: "normal",
  });
  assert.equal(u.weekly.length, 2);
  assert.equal(u.weekly[0].label, "All models");
  assert.equal(u.weekly[0].pct, 3);
  assert.equal(u.weekly[1].label, "Fable"); // scope.model.display_name
});

test("normalizeUsage falls back to five_hour/seven_day when limits[] is absent", () => {
  const u = normalizeUsage({ five_hour: SAMPLE.five_hour, seven_day: SAMPLE.seven_day });
  assert.equal(u.session?.pct, 45);
  assert.equal(u.session?.label, "Session");
  assert.equal(u.weekly.length, 1);
  assert.equal(u.weekly[0].label, "All models");
  assert.equal(u.weekly[0].pct, 3);
});

test("normalizeUsage is fail-soft on garbage input", () => {
  assert.deepEqual(normalizeUsage(null), { session: null, weekly: [] });
  assert.deepEqual(normalizeUsage({}), { session: null, weekly: [] });
  assert.deepEqual(normalizeUsage({ limits: "nope" }), { session: null, weekly: [] });
});

test("normalizeUsage tolerates a scoped weekly limit with no display name", () => {
  const u = normalizeUsage({
    limits: [{ kind: "weekly_scoped", group: "weekly", percent: 10, resets_at: null, scope: {} }],
  });
  assert.equal(u.weekly[0].label, "Scoped");
  assert.equal(u.weekly[0].resetsAt, null);
});

test("GET /usage/plan is bearer-gated and fail-soft (gateway mode → usage null)", async () => {
  const { openDb } = await import("./db.js");
  const { buildApp } = await import("./app.js");
  const { createPairingCode } = await import("./auth.js");
  const db = openDb(":memory:");
  const app = await buildApp(db, {} as any, new Map());
  assert.equal((await app.inject({ method: "GET", url: "/usage/plan" })).statusCode, 401);

  const { token } = (
    await app.inject({ method: "POST", url: "/pair", payload: { code: createPairingCode(db), device_name: "t" } })
  ).json();
  const prev = process.env.VIBE_GATEWAY_URL;
  process.env.VIBE_GATEWAY_URL = "http://127.0.0.1:1"; // no Max token upstream → no network call
  try {
    const res = await app.inject({ method: "GET", url: "/usage/plan", headers: { authorization: `Bearer ${token}` } });
    assert.equal(res.statusCode, 200);
    assert.deepEqual(res.json(), { usage: null, fetchedAt: null });
  } finally {
    if (prev === undefined) delete process.env.VIBE_GATEWAY_URL;
    else process.env.VIBE_GATEWAY_URL = prev;
  }
});

// Captured from a real SDK 0.3.291 rate_limit_event on a Max plan.
const EVENT = {
  status: "allowed",
  resetsAt: 1791317400,
  rateLimitType: "five_hour",
  unifiedWindows: {
    five_hour: { utilization: 0.09, resetsAt: 1791317400 },
    seven_day: { utilization: 0.21, resetsAt: 1791727200 },
  },
};

// Point readToken at a throwaway credentials file and count endpoint calls.
async function withFakeEndpoint(fn: (calls: () => number) => Promise<void>) {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "usage-"));
  fs.mkdirSync(path.join(home, ".claude"));
  fs.writeFileSync(path.join(home, ".claude", ".credentials.json"), JSON.stringify({ claudeAiOauth: { accessToken: "t" } }));
  const prevHome = process.env.HOME;
  const prevFetch = globalThis.fetch;
  let n = 0;
  process.env.HOME = home;
  globalThis.fetch = (async () => {
    n++;
    return new Response(JSON.stringify(SAMPLE), { status: 200 });
  }) as typeof fetch;
  resetUsageCache();
  try {
    await fn(() => n);
  } finally {
    process.env.HOME = prevHome;
    globalThis.fetch = prevFetch;
    resetUsageCache();
    fs.rmSync(home, { recursive: true });
  }
}

test("ingestRateLimit seeds an empty cache from unifiedWindows (0..1 → %, epoch s → ISO)", async () => {
  await withFakeEndpoint(async () => {
    globalThis.fetch = (async () => new Response("", { status: 429 })) as typeof fetch; // endpoint limited
    ingestRateLimit(EVENT);
    assert.deepEqual(await getUsage(), {
      session: { label: "Session", pct: 9, resetsAt: "2026-10-06T20:10:00.000Z" },
      weekly: [{ label: "All models", pct: 21, resetsAt: "2026-10-11T14:00:00.000Z" }],
    });
  });
});

test("ingestRateLimit updates 5h + 7d-all but keeps per-model limits and severity", async () => {
  await withFakeEndpoint(async (calls) => {
    await getUsage(); // endpoint fetch → SAMPLE
    ingestRateLimit(EVENT);
    const u = (await getUsage())!;
    assert.equal(calls(), 1);
    assert.equal(u.session?.pct, 9);
    assert.equal(u.session?.severity, "normal");
    assert.equal(u.weekly.length, 2);
    assert.equal(u.weekly[0].pct, 21);
    assert.equal(u.weekly[1].label, "Fable");
    assert.equal(u.weekly[1].pct, 3);
  });
});

test("events hold the cache fresh past the 5-min TTL; full refetch after 30 min", async () => {
  await withFakeEndpoint(async (calls) => {
    const t0 = Date.now();
    const min = 60_000;
    await getUsage(t0);
    for (const t of [4, 8, 12, 16, 20, 24, 28]) {
      ingestRateLimit(EVENT, t0 + t * min);
      await getUsage(t0 + (t + 1) * min);
    }
    assert.equal(calls(), 1);
    ingestRateLimit(EVENT, t0 + 31 * min);
    await getUsage(t0 + 31 * min);
    assert.equal(calls(), 2);
  });
});

test("ingestRateLimit ignores garbage and gateway mode", async () => {
  await withFakeEndpoint(async () => {
    ingestRateLimit(null);
    ingestRateLimit({ status: "allowed" });
    ingestRateLimit({ unifiedWindows: { five_hour: { utilization: "9" } } });
    const prev = process.env.VIBE_GATEWAY_URL;
    process.env.VIBE_GATEWAY_URL = "http://127.0.0.1:1";
    ingestRateLimit(EVENT);
    delete process.env.VIBE_GATEWAY_URL;
    if (prev !== undefined) process.env.VIBE_GATEWAY_URL = prev;
    globalThis.fetch = (async () => new Response("", { status: 429 })) as typeof fetch;
    assert.equal(await getUsage(), null);
  });
});

const at = (iso: string) => Date.parse(iso);
const U = (sessionPct: number, sessionReset: string | null, weekPct = 90, weekReset: string | null = null) => ({
  session: { label: "Session", pct: sessionPct, resetsAt: sessionReset },
  weekly: [
    { label: "All models", pct: weekPct, resetsAt: weekReset },
    { label: "Fable", pct: 0, resetsAt: "2026-10-06T20:30:00Z" }, // per-model: never nudged
  ],
});

test("dueNudges: session window <30 min from reset and <50% used", () => {
  const now = at("2026-10-06T20:00:00Z");
  assert.deepEqual(dueNudges(U(20, "2026-10-06T20:20:00Z"), now), [`Session@${Math.round(at("2026-10-06T20:20:00Z") / 60_000)}`]);
  assert.deepEqual(dueNudges(U(20, "2026-10-06T20:45:00Z"), now), []); // too early
  assert.deepEqual(dueNudges(U(60, "2026-10-06T20:20:00Z"), now), []); // already well used
  assert.deepEqual(dueNudges(U(20, "2026-10-06T19:59:00Z"), now), []); // already reset
  assert.deepEqual(dueNudges(U(20, null), now), []);
  assert.deepEqual(dueNudges(null, now), []);
});

test("dueNudges: weekly All-models uses a 12 h lead; same reset from endpoint vs event → same key", () => {
  const now = at("2026-10-11T04:00:00Z");
  const a = dueNudges(U(90, null, 30, "2026-10-11T13:59:59.672088+00:00"), now);
  const b = dueNudges(U(90, null, 30, "2026-10-11T14:00:00.000Z"), now);
  assert.equal(a.length, 1);
  assert.deepEqual(a, b);
  assert.deepEqual(dueNudges(U(90, null, 30, "2026-10-11T17:00:00Z"), now), []); // 13 h out
});

test("startUsageNudger pushes once per window reset, content-free", async () => {
  const { openDb } = await import("./db.js");
  const db = openDb(":memory:");
  const soon = new Date(Date.now() + 10 * 60_000).toISOString();
  const sent: [string, string][] = [];
  const stop = startUsageNudger(db, {
    intervalMs: 5,
    usage: async () => U(10, soon),
    notify: (_db, type, sessionId) => void sent.push([type, sessionId]),
  });
  await new Promise((r) => setTimeout(r, 40));
  stop();
  assert.deepEqual(sent, [["usage_reset", ""]]);
  const row = db.prepare("SELECT kind FROM events WHERE kind = 'usage.nudge'").get();
  assert.ok(row);
});
