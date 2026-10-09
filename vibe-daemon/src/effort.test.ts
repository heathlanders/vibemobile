// Reasoning effort (proposal 39): persisted per session, applied at start and live.

import { REPO_DIR } from "./test-paths.js";
import test from "node:test";
import assert from "node:assert/strict";
import { WebSocket } from "ws";
import type { AddressInfo } from "node:net";
import { openDb } from "./db.js";
import { buildApp } from "./app.js";
import { createPairingCode } from "./auth.js";
import { ClaudeSession, EFFORT_LEVELS } from "./claude.js";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
async function waitFor(fn: () => boolean, ms = 2000) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) {
    if (fn()) return;
    await sleep(5);
  }
  throw new Error("timed out");
}
const fakeWs = () => {
  const frames: any[] = [];
  return { OPEN: 1, readyState: 1, frames, send: (s: string) => frames.push(JSON.parse(s)), on() {}, ping() {}, terminate() {}, close() {} } as any;
};

function make(opts: { storedEffort?: string | null; refuse?: boolean } = {}) {
  const flags: Record<string, unknown>[] = [];
  const seen: { options?: any } = {};
  const queryFn = (params: { prompt: AsyncIterable<any>; options: any }) => {
    if (!params.options?.canUseTool) return (async function* () {})();
    seen.options = params.options;
    const gen: any = (async function* () {
      yield { type: "system", subtype: "init", session_id: "c", model: "m" };
      for await (const _ of params.prompt) yield { type: "result", subtype: "success", total_cost_usd: 0 };
    })();
    gen.applyFlagSettings = async (s: Record<string, unknown>) => {
      if (opts.refuse) throw new Error("nope");
      flags.push(s);
    };
    return gen;
  };
  const db = openDb(":memory:");
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES ('p','/tmp','p','unknown')").run();
  db.prepare("INSERT INTO sessions (id, project_id, kind, status, created_at, effort) VALUES ('s','p','claude','live',?,?)").run(
    new Date().toISOString(), opts.storedEffort ?? null,
  );
  const ws = fakeWs();
  const s = new ClaudeSession(db, "s", "/tmp", queryFn as any);
  s.attach(ws);
  s.start();
  const row = () => (db.prepare("SELECT effort FROM sessions WHERE id='s'").get() as any).effort;
  return { db, ws, s, flags, seen, row };
}

test("no stored effort → the SDK gets none (model default); attach reports null and the level list", () => {
  const { seen, ws } = make();
  assert.equal(seen.options.effort, undefined);
  assert.deepEqual(ws.frames.find((f: any) => f.t === "effort"), { t: "effort", effort: null, levels: [...EFFORT_LEVELS] });
});

test("a stored effort is passed at start — a resumed or restarted session keeps its level", () => {
  const { seen, ws } = make({ storedEffort: "max" });
  assert.equal(seen.options.effort, "max");
  assert.equal(ws.frames.find((f: any) => f.t === "effort").effort, "max");
});

test("a garbage stored value is ignored, never forwarded to the SDK", () => {
  const { seen } = make({ storedEffort: "turbo" });
  assert.equal(seen.options.effort, undefined);
});

test("setEffort: applied live, persisted, announced, audited", async () => {
  const { s, flags, row, ws, db } = make();
  assert.equal(await s.setEffort("high", "dev1"), true);
  assert.deepEqual(flags, [{ effortLevel: "high" }]);
  assert.equal(row(), "high");
  assert.deepEqual(ws.frames.filter((f: any) => f.t === "effort").pop(), { t: "effort", effort: "high", levels: [...EFFORT_LEVELS] });
  assert.deepEqual(db.prepare("SELECT kind, device_id, detail FROM events WHERE kind='session.effort'").get(), {
    kind: "session.effort", device_id: "dev1", detail: "s:high",
  });
});

test("every whitelisted level works; null returns to the model default", async () => {
  const { s, flags, row } = make();
  for (const lvl of EFFORT_LEVELS) assert.equal(await s.setEffort(lvl), true, lvl);
  assert.equal(await s.setEffort(null), true);
  assert.equal(row(), null);
  assert.deepEqual(flags.at(-1), { effortLevel: null });
});

test("setEffort refuses unknown levels and no-ops — nothing changes, nothing is sent to the SDK", async () => {
  const { s, flags, row } = make({ storedEffort: "low" });
  for (const bad of ["turbo", "", "HIGH", "high ", "max; rm -rf", "__proto__"]) assert.equal(await s.setEffort(bad), false, JSON.stringify(bad));
  assert.equal(await s.setEffort("low"), false, "same level");
  assert.deepEqual(flags, []);
  assert.equal(row(), "low");
});

test("if the SDK refuses, the stored level and the frame are unchanged", async () => {
  const { s, row, ws } = make({ refuse: true });
  assert.equal(await s.setEffort("high"), false);
  assert.equal(row(), null);
  assert.equal(ws.frames.filter((f: any) => f.t === "effort").length, 1, "only the attach-time frame");
});

test("a stopped session ignores setEffort", async () => {
  const { s, flags } = make();
  s.stop();
  assert.equal(await s.setEffort("high"), false);
  assert.deepEqual(flags, []);
});

test("WS: set_effort reaches the session; junk frames are dropped; null resets", async (t) => {
  const flags: unknown[] = [];
  const queryFn = (params: { prompt: AsyncIterable<any>; options: any }) => {
    if (!params.options?.canUseTool) return (async function* () {})();
    const gen: any = (async function* () {
      yield { type: "system", subtype: "init", session_id: "c", model: "m" };
      for await (const _ of params.prompt) yield { type: "result", subtype: "success", total_cost_usd: 0 };
    })();
    gen.applyFlagSettings = async (s: unknown) => void flags.push(s);
    return gen;
  };
  const db = openDb(":memory:");
  const app = await buildApp(db, undefined, new Map(), queryFn);
  await app.listen({ host: "127.0.0.1", port: 0 });
  t.after(() => app.close());
  const port = (app.server.address() as AddressInfo).port;
  const { token } = (await app.inject({ method: "POST", url: "/pair", payload: { code: createPairingCode(db), device_name: "t" } })).json();
  db.prepare(`INSERT INTO projects (id, path, name, type) VALUES ('p','${REPO_DIR}','p','unknown')`).run();
  const created = (await app.inject({ method: "POST", url: "/sessions", headers: { authorization: `Bearer ${token}` }, payload: { project_id: "p", kind: "claude" } })).json();
  const frames: any[] = [];
  const ws = new WebSocket(`ws://127.0.0.1:${port}/session/${created.id}`, { headers: { authorization: `Bearer ${token}` } });
  ws.on("message", (d: Buffer) => frames.push(JSON.parse(d.toString("utf8"))));
  await new Promise<void>((res) => ws.on("open", () => res()));
  await waitFor(() => frames.some((f) => f.t === "effort"));
  for (const f of [{ effort: 5 }, { effort: "turbo" }, { effort: ["max"] }, {}]) ws.send(JSON.stringify({ t: "set_effort", ...f }));
  ws.send(JSON.stringify({ t: "set_effort", effort: "max" }));
  await waitFor(() => frames.filter((f) => f.t === "effort").length >= 2);
  ws.send(JSON.stringify({ t: "set_effort", effort: null }));
  await waitFor(() => frames.filter((f) => f.t === "effort").length >= 3);
  assert.deepEqual(flags, [{ effortLevel: "max" }, { effortLevel: null }]);
  assert.deepEqual(frames.filter((f) => f.t === "effort").map((f) => f.effort), [null, "max", null]);
  ws.close();
});
