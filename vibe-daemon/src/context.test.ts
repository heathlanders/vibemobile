// Context meter + compaction (proposal 40, M12 spike).

import { REPO_DIR } from "./test-paths.js";
import test from "node:test";
import assert from "node:assert/strict";
import { WebSocket } from "ws";
import type { AddressInfo } from "node:net";
import { openDb } from "./db.js";
import { buildApp } from "./app.js";
import { createPairingCode } from "./auth.js";
import { ClaudeSession } from "./claude.js";
import { compactNotice, summarizeContext } from "./context.js";

// Shape captured from the real SDK (trimmed): camelCase, categories classified by `kind`.
const REAL = {
  categories: [
    { name: "System prompt", tokens: 141, color: "x", kind: "used" },
    { name: "System tools", tokens: 8835, color: "x", kind: "used" },
    { name: "Messages", tokens: 4806, color: "x", kind: "used" },
    { name: "System tools (deferred)", tokens: 26344, color: "x", kind: "deferred", isDeferred: true },
    { name: "Autocompact buffer", tokens: 33000, color: "x", kind: "buffer" },
    { name: "Free space", tokens: 945471, color: "x", kind: "free" },
  ],
  totalTokens: 21502,
  maxTokens: 1000000,
  rawMaxTokens: 1000000,
  percentage: 2,
  model: "claude-sonnet-5-5",
  autoCompactThreshold: 967000,
  isAutoCompactEnabled: true,
  memoryFiles: [
    { path: "/home/user/vibemobile/CLAUDE.md", type: "Project", tokens: 1489 },
    { path: "/home/user/.claude/projects/-home-user-vibemobile/memory/MEMORY.md", type: "AutoMem", tokens: 344 },
  ],
};

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

// ---- pure ------------------------------------------------------------------------------------

test("summarizeContext: tokens/max/percent, auto-compact point, only 'used' categories, largest first", () => {
  const c = summarizeContext(REAL)!;
  assert.deepEqual([c.tokens, c.max, c.percent, c.autoCompactAt, c.model], [21502, 1000000, 2, 967000, "claude-sonnet-5-5"]);
  assert.deepEqual(c.categories, [
    { name: "System tools", tokens: 8835 },
    { name: "Messages", tokens: 4806 },
    { name: "System prompt", tokens: 141 },
  ], "free/buffer/deferred rows don't occupy the window");
});

test("summarizeContext: lists the instruction files the session loaded", () => {
  assert.deepEqual(summarizeContext(REAL)!.memoryFiles, [
    { path: "/home/user/vibemobile/CLAUDE.md", type: "Project", tokens: 1489 },
    { path: "/home/user/.claude/projects/-home-user-vibemobile/memory/MEMORY.md", type: "AutoMem", tokens: 344 },
  ]);
  const { memoryFiles: _m, ...none } = REAL;
  assert.deepEqual(summarizeContext(none)!.memoryFiles, [], "absent → empty");
  const junk = summarizeContext({ ...REAL, memoryFiles: [null, 3, {}, { path: "" }, { path: 5 }, { path: "/ok.md", type: 9, tokens: "x" }] })!;
  assert.deepEqual(junk.memoryFiles, [{ path: "/ok.md", type: "", tokens: 0 }]);
  const many = summarizeContext({ ...REAL, memoryFiles: Array.from({ length: 50 }, (_, i) => ({ path: `/f${i}.md`, type: "Project", tokens: 1 })) })!;
  assert.equal(many.memoryFiles.length, 20, "capped");
});

test("summarizeContext: auto-compact off → null; percent derived when absent; rawMax fallback", () => {
  assert.equal(summarizeContext({ ...REAL, isAutoCompactEnabled: false })!.autoCompactAt, null);
  const { percentage: _p, maxTokens: _m, ...rest } = REAL;
  const c = summarizeContext({ ...rest, totalTokens: 250000, rawMaxTokens: 1000000 })!;
  assert.equal(c.percent, 25);
  assert.equal(c.max, 1000000);
});

test("summarizeContext: garbage never throws and yields null or a smaller frame", () => {
  for (const bad of [null, undefined, 5, "x", [], {}, { totalTokens: 1 }, { totalTokens: 1, maxTokens: 0 }, { totalTokens: NaN, maxTokens: 10 }, { totalTokens: "1", maxTokens: "2" }]) {
    assert.equal(summarizeContext(bad), null, JSON.stringify(bad));
  }
  const weird = summarizeContext({ totalTokens: 5, maxTokens: 10, categories: "nope", model: 7 })!;
  assert.deepEqual([weird.categories, weird.model, weird.percent], [[], null, 50]);
  assert.deepEqual(summarizeContext({ totalTokens: 5, maxTokens: 10, categories: [null, 3, { kind: "used", name: 4, tokens: 1 }, { kind: "used", name: "ok", tokens: 0 }] })!.categories, []);
});

test("compactNotice formats the boundary metadata, with and without token counts", () => {
  assert.equal(compactNotice({ trigger: "manual", pre_tokens: 24261, post_tokens: 2806 }), "Context compacted (manual): 24,261 → 2,806 tokens");
  assert.equal(compactNotice({ trigger: "auto", pre_tokens: 900000, post_tokens: 40000 }), "Context compacted (auto): 900,000 → 40,000 tokens");
  assert.equal(compactNotice({ trigger: "auto" }), "Context compacted (auto)");
  assert.equal(compactNotice(undefined), "Context compacted (manual)");
});

// ---- session ----------------------------------------------------------------------------------

type Opts = { usage?: () => Promise<unknown>; script?: (prompt: any) => AsyncGenerator<any>; rules?: boolean };
function make(opts: Opts = {}) {
  const inputs: any[] = [];
  const usageCalls: unknown[] = [];
  const queryFn = (params: { prompt: AsyncIterable<any>; options: any }) => {
    if (!params.options?.canUseTool) return (async function* () {})();
    const gen: any = (async function* () {
      yield { type: "system", subtype: "init", session_id: "c", model: "m" };
      for await (const m of params.prompt) {
        inputs.push(m);
        if (opts.script) yield* opts.script(m);
        else yield { type: "result", subtype: "success", total_cost_usd: 0 };
      }
    })();
    gen.getContextUsage = async (o: unknown) => {
      usageCalls.push(o);
      return opts.usage ? opts.usage() : REAL;
    };
    return gen;
  };
  const db = openDb(":memory:");
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES ('p','/tmp','p','unknown')").run();
  db.prepare("INSERT INTO sessions (id, project_id, kind, status, created_at) VALUES ('s','p','claude','live',?)").run(new Date().toISOString());
  if (opts.rules === false) db.prepare("INSERT INTO settings (key, value, updated_at) VALUES ('rules.enabled', 'false', ?)").run(new Date().toISOString());
  const ws = fakeWs();
  const s = new ClaudeSession(db, "s", "/tmp", queryFn as any);
  s.attach(ws);
  s.start();
  return { db, ws, s, inputs, usageCalls };
}
const results = (ws: any) => ws.frames.filter((f: any) => f.t === "result").length;

test("a context frame follows every turn (summary detail: cheap)", async () => {
  const { s, ws, usageCalls } = make();
  s.pushUser("hi");
  await waitFor(() => ws.frames.some((f: any) => f.t === "context"));
  const f = ws.frames.find((x: any) => x.t === "context");
  assert.deepEqual([f.tokens, f.max, f.percent, f.autoCompactAt], [21502, 1000000, 2, 967000]);
  assert.equal(f.categories[0].name, "System tools");
  assert.deepEqual(usageCalls[0], { detail: "summary" });
});

test("the context frame says whether the daemon's session rules were applied to THIS session", async () => {
  const on = make();
  on.s.pushUser("hi");
  await waitFor(() => on.ws.frames.some((f: any) => f.t === "context"));
  assert.equal(on.ws.frames.find((f: any) => f.t === "context").rules, true, "rules are on by default");
  assert.equal(on.ws.frames.find((f: any) => f.t === "context").memoryFiles[0].type, "Project");

  const off = make({ rules: false });
  off.s.pushUser("hi");
  await waitFor(() => off.ws.frames.some((f: any) => f.t === "context"));
  assert.equal(off.ws.frames.find((f: any) => f.t === "context").rules, false);
});

test("attach replays the last reading at once and asks for a fresh one when idle", async () => {
  const { s, ws } = make();
  s.pushUser("hi");
  await waitFor(() => ws.frames.some((f: any) => f.t === "context"));
  const ws2 = fakeWs();
  s.attach(ws2);
  assert.equal(ws2.frames.filter((f: any) => f.t === "context").length >= 1, true, "cached reading is sent synchronously");
  await waitFor(() => ws2.frames.filter((f: any) => f.t === "context").length === 2);
});

test("a failing or malformed usage read produces no frame and never breaks the turn", async () => {
  for (const usage of [async () => { throw new Error("boom"); }, async () => ({ nonsense: true }), async () => null]) {
    const { s, ws } = make({ usage });
    s.pushUser("hi");
    await waitFor(() => results(ws) === 1);
    await sleep(40);
    assert.equal(ws.frames.some((f: any) => f.t === "context" || f.t === "error"), false);
  }
});

test("compact: streams '/compact' to the SDK, is NOT stored as a user message, is audited", async () => {
  const { s, ws, inputs, db } = make();
  s.pushUser("first");
  await waitFor(() => results(ws) === 1);
  assert.equal(s.compact("dev1"), true);
  await waitFor(() => inputs.length === 2);
  assert.equal(inputs[1].message.content, "/compact");
  await waitFor(() => results(ws) === 2);
  assert.equal((db.prepare("SELECT COUNT(*) n FROM messages WHERE role='user'").get() as any).n, 1, "only the real user turn is stored");
  assert.deepEqual(db.prepare("SELECT kind, device_id, detail FROM events WHERE kind='session.compact'").get(), { kind: "session.compact", device_id: "dev1", detail: "s" });
});

test("compact is refused mid-turn, when stopped, and before the engine started", async () => {
  let release = () => {};
  const held = make({ script: async function* () { await new Promise<void>((r) => (release = r)); yield { type: "result", subtype: "success", total_cost_usd: 0 }; } });
  held.s.pushUser("long");
  await waitFor(() => held.inputs.length === 1);
  assert.equal(held.s.compact(), false, "a turn is running");
  release();
  await waitFor(() => results(held.ws) === 1);
  held.s.stop();
  assert.equal(held.s.compact(), false, "stopped");
  const db = openDb(":memory:");
  const fresh = new ClaudeSession(db, "s", "/tmp", (() => (async function* () {})()) as any);
  assert.equal(fresh.compact(), false, "never started");
});

test("compact_boundary becomes a persisted notice + a `compacted` frame; the string user messages that follow don't crash anything", async () => {
  const script = async function* (m: any) {
    if (m.message.content === "/compact") {
      yield { type: "system", subtype: "compact_boundary", compact_metadata: { trigger: "manual", pre_tokens: 24261, post_tokens: 2806 } };
      yield { type: "user", message: { role: "user", content: "This session is being continued from a previous conversation…" } };
      yield { type: "user", message: { role: "user", content: "<local-command-stdout>Compacted </local-command-stdout>" } };
      yield { type: "result", subtype: "success", total_cost_usd: 0 };
    } else {
      yield { type: "result", subtype: "success", total_cost_usd: 0 };
    }
  };
  const { s, ws, db } = make({ script });
  s.pushUser("first");
  await waitFor(() => results(ws) === 1);
  s.compact();
  await waitFor(() => results(ws) === 2);
  const f = ws.frames.find((x: any) => x.t === "compacted");
  assert.deepEqual([f.text, f.trigger, f.preTokens, f.postTokens], ["Context compacted (manual): 24,261 → 2,806 tokens", "manual", 24261, 2806]);
  assert.equal(ws.frames.some((x: any) => x.t === "error"), false);
  const row = db.prepare("SELECT role, content FROM messages WHERE role='notice'").get() as any;
  assert.equal(row.content, f.text);
  const ws2 = fakeWs();
  s.attach(ws2);
  assert.ok(ws2.frames.find((x: any) => x.t === "history").messages.some((m: any) => m.role === "notice" && m.content === f.text), "replays after reattach");
  s.pushUser("still alive"); // the reattached socket (ws2) is the live one now
  await waitFor(() => results(ws2) === 1);
});

test("an auto compaction (no command from us) is recorded the same way", async () => {
  const script = async function* () {
    yield { type: "system", subtype: "compact_boundary", compact_metadata: { trigger: "auto", pre_tokens: 970000, post_tokens: 30000 } };
    yield { type: "result", subtype: "success", total_cost_usd: 0 };
  };
  const { s, ws } = make({ script });
  s.pushUser("big");
  await waitFor(() => ws.frames.some((f: any) => f.t === "compacted"));
  assert.equal(ws.frames.find((f: any) => f.t === "compacted").trigger, "auto");
});

test("WS: a `compact` frame reaches the session", async (t) => {
  const inputs: string[] = [];
  const queryFn = (params: { prompt: AsyncIterable<any>; options: any }) => {
    if (!params.options?.canUseTool) return (async function* () {})();
    return (async function* () {
      yield { type: "system", subtype: "init", session_id: "c", model: "m" };
      for await (const m of params.prompt) {
        inputs.push(m.message.content);
        yield { type: "result", subtype: "success", total_cost_usd: 0 };
      }
    })();
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
  ws.send(JSON.stringify({ t: "compact" }));
  await waitFor(() => inputs.includes("/compact"));
  ws.close();
});
