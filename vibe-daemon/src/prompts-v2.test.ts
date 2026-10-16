// Prompt library v2 (ADR 0018): use counts + sort, cross-session history, and the
// improve route (fake rewriter), plus improvePrompt's SDK lockdown (fake SDK).

import test from "node:test";
import assert from "node:assert/strict";
import Fastify from "fastify";
import { openDb } from "./db.js";
import { registerPromptRoutes } from "./prompts.js";
import { DEEPER_SYSTEM, IMPROVE_SYSTEM, ImproveBusy, improvePrompt } from "./prompt-improve.js";

function setup(improve?: (t: string, cwd: string) => Promise<string>) {
  const db = openDb(":memory:");
  const app = Fastify();
  registerPromptRoutes(app, db, improve);
  return { db, app };
}

test("POST /prompts/:id/use counts uses; ?sort=used orders by them", async () => {
  const { app } = setup();
  const mk = async (title: string) =>
    (await app.inject({ method: "POST", url: "/prompts", payload: { title, body: "b" } })).json().id as string;
  const a = await mk("a");
  const b = await mk("b");
  for (let i = 0; i < 3; i++) assert.equal((await app.inject({ method: "POST", url: `/prompts/${b}/use` })).statusCode, 204);
  await app.inject({ method: "POST", url: `/prompts/${a}/use` });
  assert.equal((await app.inject({ method: "POST", url: "/prompts/nope/use" })).statusCode, 404);

  const used = (await app.inject({ method: "GET", url: "/prompts?sort=used" })).json();
  assert.deepEqual(used.slice(0, 2).map((p: any) => [p.title, p.use_count]), [["b", 3], ["a", 1]]);
  assert.ok(used[0].last_used_at);
});

test("GET /prompts/history: user turns across sessions, deduped, LIKE-escaped", async () => {
  const { db, app } = setup();
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES ('p1','/tmp/a','alpha','unknown')").run();
  const now = Date.now();
  for (const s of ["s1", "s2"]) {
    db.prepare("INSERT INTO sessions (id, project_id, kind, status, created_at) VALUES (?,?,?,?,?)").run(s, "p1", "claude", "live", "x");
  }
  const add = (sid: string, role: string, content: string, ago: number) =>
    db.prepare("INSERT INTO messages (id, session_id, role, content, ts) VALUES (?,?,?,?,?)")
      .run(`${sid}-${ago}-${role}`, sid, role, content, new Date(now - ago * 1000).toISOString());
  add("s1", "user", "run the tests", 30);
  add("s2", "user", "run the tests", 10);
  add("s1", "assistant", "run the tests? sure", 20);
  add("s2", "user", "fix 100% of lint", 5);
  add("s2", "user", "   ", 1);

  const all = (await app.inject({ method: "GET", url: "/prompts/history" })).json();
  assert.deepEqual(all.map((r: any) => [r.text, r.times, r.project]), [
    ["fix 100% of lint", 1, "alpha"],
    ["run the tests", 2, "alpha"],
  ]);
  const pct = (await app.inject({ method: "GET", url: "/prompts/history?q=100%25" })).json();
  assert.deepEqual(pct.map((r: any) => r.text), ["fix 100% of lint"]);
  const literal = (await app.inject({ method: "GET", url: "/prompts/history?q=%25" })).json();
  assert.equal(literal.length, 1, "% is matched literally, not as a wildcard");
});

test("POST /prompts/improve: validates, returns the rewrite, maps busy/failure", async () => {
  let seen = "";
  const { app } = setup(async (t) => {
    seen = t;
    return "Better prompt";
  });
  assert.equal((await app.inject({ method: "POST", url: "/prompts/improve", payload: {} })).statusCode, 400);
  assert.equal((await app.inject({ method: "POST", url: "/prompts/improve", payload: { text: "x".repeat(20_001) } })).statusCode, 413);
  const ok = await app.inject({ method: "POST", url: "/prompts/improve", payload: { text: "make it work" } });
  assert.deepEqual(ok.json(), { text: "Better prompt" });
  assert.equal(seen, "make it work");

  const busy = setup(async () => {
    throw new ImproveBusy("busy");
  });
  assert.equal((await busy.app.inject({ method: "POST", url: "/prompts/improve", payload: { text: "a" } })).statusCode, 429);
  const broken = setup(async () => {
    throw new Error("boom");
  });
  assert.equal((await broken.app.inject({ method: "POST", url: "/prompts/improve", payload: { text: "a" } })).statusCode, 502);
});

test("improvePrompt runs locked down (no tools/settings/MCP) and strips a code fence", async () => {
  let opts: any;
  const fake = (p: { prompt: string; options: any }) => {
    opts = p.options;
    return (async function* () {
      yield { type: "result", subtype: "success", result: "```\nRewritten {{file}}\n```" };
    })();
  };
  assert.equal(await improvePrompt("fix {{file}}", "/tmp", fake as any), "Rewritten {{file}}");
  assert.deepEqual([opts.tools, opts.allowedTools, opts.settingSources, opts.mcpServers, opts.maxTurns], [[], [], [], {}, 1]);
  assert.equal(opts.permissionMode, "default");
  assert.equal(opts.persistSession, false);

  const empty = (() => (async function* () {})()) as any;
  await assert.rejects(improvePrompt("x", "/tmp", empty), /no rewrite/);
});

test("POST /prompts/improve: mode is whitelisted and passed through (default improve)", async () => {
  const seen: (string | undefined)[] = [];
  const { app } = setup(async (_t, _c, mode) => (seen.push(mode), "ok"));
  const post = (payload: object) => app.inject({ method: "POST", url: "/prompts/improve", payload });
  assert.equal((await post({ text: "a", mode: "deeper" })).statusCode, 200);
  assert.equal((await post({ text: "a" })).statusCode, 200);
  assert.equal((await post({ text: "a", mode: "evil" })).statusCode, 400);
  assert.equal((await post({ text: "a", mode: 3 })).statusCode, 400);
  assert.deepEqual(seen, ["deeper", "improve"]);
});

test("improvePrompt deeper mode uses DEEPER_SYSTEM with the same lockdown", async () => {
  let opts: any;
  const fake = (p: { options: any }) => {
    opts = p.options;
    return (async function* () { yield { type: "result", subtype: "success", result: "deep" }; })();
  };
  assert.equal(await improvePrompt("x", "/tmp", fake as any, "deeper"), "deep");
  assert.equal(opts.systemPrompt, DEEPER_SYSTEM);
  assert.deepEqual([opts.tools, opts.settingSources, opts.mcpServers], [[], [], {}]);
  await improvePrompt("x", "/tmp", fake as any);
  assert.equal(opts.systemPrompt, IMPROVE_SYSTEM);
});
