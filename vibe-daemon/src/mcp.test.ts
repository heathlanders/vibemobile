// MCP servers view (proposal 43): summarizing never leaks launch config/secrets; actions
// are limited to servers the SDK itself lists.

import { REPO_DIR } from "./test-paths.js";
import test from "node:test";
import assert from "node:assert/strict";
import { WebSocket } from "ws";
import type { AddressInfo } from "node:net";
import { openDb } from "./db.js";
import { buildApp } from "./app.js";
import { createPairingCode } from "./auth.js";
import { ClaudeSession } from "./claude.js";
import { parseMcpAction, summarizeMcp } from "./mcp.js";

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

const SECRET = "sk-live-SUPERSECRET-123";
const RAW = [
  {
    name: "github", status: "connected", scope: "user", source: "user",
    serverInfo: { name: "github-mcp", version: "1.4.2" },
    config: { type: "stdio", command: "npx", args: ["-y", "gh-mcp", `--token=${SECRET}`], env: { GITHUB_TOKEN: SECRET } },
    tools: [
      { name: "search_code", description: "Search\n  code   across repos", annotations: { readOnly: true } },
      { name: "delete_repo", description: "Delete a repository", annotations: { destructive: true } },
      { name: "plain" },
    ],
  },
  { name: "claude.ai Gmail", status: "needs-auth", scope: "claudeai", config: { type: "http", url: `https://mcp.example/x?token=${SECRET}` } },
  { name: "broken", status: "failed", error: `spawn /usr/bin/x ENOENT with ${"e".repeat(500)}`, config: { command: "/usr/bin/x" } },
  { name: "later", status: "some-new-state" },
];

test("summarizeMcp: names, state, version, scope, tool list with annotations — and NOTHING from `config`", () => {
  const { servers, truncated } = summarizeMcp(RAW);
  assert.equal(truncated, false);
  const gh = servers[0];
  assert.deepEqual([gh.name, gh.status, gh.version, gh.scope, gh.toolCount], ["github", "connected", "1.4.2", "user", 3]);
  assert.deepEqual(gh.tools, [
    { name: "search_code", description: "Search code across repos", readOnly: true },
    { name: "delete_repo", description: "Delete a repository", destructive: true },
    { name: "plain", description: "" },
  ]);
  const wire = JSON.stringify(summarizeMcp(RAW));
  assert.ok(!wire.includes(SECRET), "no secret anywhere in the frame");
  for (const leak of ["GITHUB_TOKEN", "--token", "npx", "mcp.example", "command", "args", "env"]) {
    assert.ok(!wire.includes(leak), `config detail "${leak}" must not be forwarded`);
  }
});

test("summarizeMcp: unknown states become 'unknown', errors are clipped, a failed server keeps its reason", () => {
  const { servers } = summarizeMcp(RAW);
  assert.equal(servers[1].status, "needs-auth");
  assert.equal(servers[2].status, "failed");
  assert.equal(servers[2].error!.length, 200);
  assert.match(servers[2].error!, /^spawn \/usr\/bin\/x ENOENT/);
  assert.equal(servers[3].status, "unknown");
  assert.equal(servers[3].toolCount, 0);
});

test("summarizeMcp caps servers and total tools and says so; junk never throws", () => {
  const many = Array.from({ length: 80 }, (_, i) => ({ name: `s${i}`, status: "connected", tools: [] }));
  const r = summarizeMcp(many);
  assert.equal(r.servers.length, 50);
  assert.equal(r.truncated, true);
  const big = summarizeMcp([{ name: "big", status: "connected", tools: Array.from({ length: 1000 }, (_, i) => ({ name: `t${i}` })) }]);
  assert.equal(big.servers[0].tools.length, 400);
  assert.equal(big.servers[0].toolCount, 1000, "the real count is still reported");
  assert.equal(big.truncated, true);
  for (const junk of [null, undefined, 5, "x", {}, [null, 3, "s", {}, { name: "" }, { name: 7 }, { name: "ok", tools: "nope" }]]) {
    assert.doesNotThrow(() => summarizeMcp(junk), JSON.stringify(junk));
  }
  assert.deepEqual(summarizeMcp([{ name: "ok", tools: "nope" }]).servers.map((s) => s.name), ["ok"]);
});

test("parseMcpAction whitelists reconnect / enable / disable", () => {
  for (const a of ["reconnect", "enable", "disable"]) assert.equal(parseMcpAction(a), a);
  for (const bad of ["restart", "", "Enable", "delete", 5, null, undefined, "disable; rm"]) assert.equal(parseMcpAction(bad), null);
});

function make(opts: { status?: () => Promise<unknown>; fail?: boolean } = {}) {
  const calls: string[] = [];
  const queryFn = (params: { prompt: AsyncIterable<any>; options: any }) => {
    if (!params.options?.canUseTool) return (async function* () {})();
    const gen: any = (async function* () {
      yield { type: "system", subtype: "init", session_id: "c", model: "m" };
      for await (const _ of params.prompt) yield { type: "result", subtype: "success", total_cost_usd: 0 };
    })();
    gen.mcpServerStatus = async () => (opts.status ? opts.status() : RAW);
    gen.reconnectMcpServer = async (n: string) => {
      if (opts.fail) throw new Error("nope");
      calls.push(`reconnect:${n}`);
    };
    gen.toggleMcpServer = async (n: string, e: boolean) => {
      if (opts.fail) throw new Error("nope");
      calls.push(`${e ? "enable" : "disable"}:${n}`);
    };
    return gen;
  };
  const db = openDb(":memory:");
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES ('p','/tmp','p','unknown')").run();
  db.prepare("INSERT INTO sessions (id, project_id, kind, status, created_at) VALUES ('s','p','claude','live',?)").run(new Date().toISOString());
  const ws = fakeWs();
  const s = new ClaudeSession(db, "s", "/tmp", queryFn as any);
  s.attach(ws);
  s.start();
  return { db, ws, s, calls };
}

test("sendMcpStatus: an `mcp` frame with the safe summary, and only when asked", async () => {
  const { s, ws } = make();
  await sleep(30);
  assert.equal(ws.frames.some((f: any) => f.t === "mcp"), false, "nothing is pushed unasked");
  s.sendMcpStatus();
  await waitFor(() => ws.frames.some((f: any) => f.t === "mcp"));
  const f = ws.frames.find((x: any) => x.t === "mcp");
  assert.equal(f.servers.length, 4);
  assert.ok(!JSON.stringify(f).includes(SECRET));
});

test("mcpAction works for servers the SDK lists, calls the right SDK method, audits, and refreshes the view", async () => {
  const { s, ws, calls, db } = make();
  assert.equal(await s.mcpAction("broken", "reconnect", "dev1"), true);
  assert.equal(await s.mcpAction("github", "disable", "dev1"), true);
  assert.equal(await s.mcpAction("github", "enable", "dev1"), true);
  assert.deepEqual(calls, ["reconnect:broken", "disable:github", "enable:github"]);
  await waitFor(() => ws.frames.filter((f: any) => f.t === "mcp").length === 3);
  assert.deepEqual((db.prepare("SELECT detail FROM events WHERE kind='session.mcp' ORDER BY ts, rowid").all() as any[]).map((e) => e.detail), ["s:reconnect:broken:ok", "s:disable:github:ok", "s:enable:github:ok"]);
});

test("mcpAction refuses unknown servers, bad actions and junk — the SDK is never called", async () => {
  const { s, calls } = make();
  assert.equal(await s.mcpAction("not-a-server", "reconnect"), false);
  assert.equal(await s.mcpAction("../../etc", "disable"), false);
  assert.equal(await s.mcpAction("github", "restart"), false);
  assert.equal(await s.mcpAction("github", ""), false);
  assert.equal(await s.mcpAction(5 as any, "enable"), false);
  assert.deepEqual(calls, []);
});

test("if the SDK rejects (a server that still won't start), mcpAction is false, the attempt IS audited as failed, and the real state is sent", async () => {
  const { s, ws, db } = make({ fail: true });
  assert.equal(await s.mcpAction("github", "disable", "dev1"), false);
  assert.equal((db.prepare("SELECT detail FROM events WHERE kind='session.mcp'").get() as any).detail, "s:disable:github:failed");
  await waitFor(() => ws.frames.some((f: any) => f.t === "mcp"));
});

test("an unknown server is neither acted on nor audited", async () => {
  const { s, db } = make();
  assert.equal(await s.mcpAction("not-a-server", "disable"), false);
  assert.equal(db.prepare("SELECT 1 FROM events WHERE kind='session.mcp'").get(), undefined);
});

test("a stopped session ignores MCP requests", async () => {
  const { s, ws, calls } = make();
  s.stop();
  assert.equal(await s.mcpAction("github", "disable"), false);
  s.sendMcpStatus();
  await sleep(30);
  assert.deepEqual(calls, []);
  assert.equal(ws.frames.some((f: any) => f.t === "mcp"), false);
});

test("WS: get_mcp returns the summary; mcp_action is dispatched; junk frames are dropped", async (t) => {
  const calls: string[] = [];
  const queryFn = (params: { prompt: AsyncIterable<any>; options: any }) => {
    if (!params.options?.canUseTool) return (async function* () {})();
    const gen: any = (async function* () {
      yield { type: "system", subtype: "init", session_id: "c", model: "m" };
      for await (const _ of params.prompt) yield { type: "result", subtype: "success", total_cost_usd: 0 };
    })();
    gen.mcpServerStatus = async () => RAW;
    gen.toggleMcpServer = async (n: string, e: boolean) => void calls.push(`${e ? "enable" : "disable"}:${n}`);
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
  ws.send(JSON.stringify({ t: "get_mcp" }));
  await waitFor(() => frames.some((f) => f.t === "mcp"));
  for (const bad of [{ server: 5, action: "enable" }, { server: "github" }, { server: "github", action: 3 }]) ws.send(JSON.stringify({ t: "mcp_action", ...bad }));
  ws.send(JSON.stringify({ t: "mcp_action", server: "github", action: "disable" }));
  await waitFor(() => calls.length === 1);
  assert.deepEqual(calls, ["disable:github"]);
  ws.close();
});
