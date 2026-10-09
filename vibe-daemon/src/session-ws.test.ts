// Claude WS integration: real app + real `ws` client + a FAKE Agent SDK (injected
// queryFn) — no real subprocess, no spend. Drives the full path: attach → history
// → user turn → deltas → permission_request → client permission → result. Plus
// 4404 (non-claude/missing) and WS auth rejection (mirrors pty-ws.test.ts).

import { REPO_DIR } from "./test-paths.js";
import test from "node:test";
import assert from "node:assert/strict";
import { WebSocket } from "ws";
import type { AddressInfo } from "node:net";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { openDb } from "./db.js";
import { buildApp } from "./app.js";
import { createPairingCode } from "./auth.js";
import { encodeProjectPath } from "./discover.js";
import type { Tmux } from "./tmux.js";

// Native sessions build a real provider model (ignored by the fake streamText).
process.env.OPENAI_API_KEY ??= "sk-test";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
async function waitFor(fn: () => boolean, ms = 2000) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) {
    if (fn()) return;
    await sleep(5);
  }
  throw new Error("timed out");
}

// No-op tmux — the claude path never touches it (DELETE killSession is harmless).
const noTmux: Tmux = {
  async ensureGlobals() {},
  async createSession() {},
  async hasSession() {
    return false;
  },
  async detachOthers() {},
  attach() {
    throw new Error("unused");
  },
  async killSession() {},
  async sweepStale() {},
};

// Same scripted SDK turn as claude.test.ts.
function fakeQuery(params: { prompt: AsyncIterable<any>; options: any }) {
  const { prompt, options } = params;
  return (async function* () {
    yield { type: "system", subtype: "init", session_id: "claude-xyz", model: "claude-x" };
    await prompt[Symbol.asyncIterator]().next();
    yield { type: "stream_event", event: { type: "content_block_delta", delta: { type: "text_delta", text: "Hi" } } };
    const d: any = await options.canUseTool("Read", { file: "README" }, { toolUseID: "tu1", title: "Read" });
    yield {
      type: "assistant",
      message: { content: [{ type: "text", text: d.behavior === "allow" ? "ok" : "no" }, { type: "tool_use", id: "tu1", name: "Read", input: {} }] },
    };
    yield { type: "result", subtype: "success", total_cost_usd: 0.02 };
  })();
}

// Same reason: the native turn below ends in reportCost, which fires the auto-titler
// refine (ADR 0009). No title queryFn is injected here, so keep the model call off.
process.env.VIBE_AUTO_TITLE_LLM = "0";

// Fake Vercel AI SDK streamText for the native path (no real API / spend).
function fakeStreamText(_args: any) {
  return {
    fullStream: (async function* () {
      yield { type: "text-delta", id: "t", text: "Yo" };
      yield { type: "finish", finishReason: "stop", totalUsage: { inputTokens: 1, outputTokens: 1 } };
    })(),
    response: Promise.resolve({ messages: [{ role: "assistant", content: "Yo" }] }),
  };
}

async function bootApp() {
  const db = openDb(":memory:");
  const app = await buildApp(db, noTmux, new Map(), fakeQuery);
  await app.listen({ host: "127.0.0.1", port: 0 });
  const port = (app.server.address() as AddressInfo).port;
  const { token } = (
    await app.inject({ method: "POST", url: "/pair", payload: { code: createPairingCode(db), device_name: "t" } })
  ).json();
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES (?,?,?,?)").run("p_ok", REPO_DIR, "vm", "unknown");
  return { db, app, port, token };
}

function connect(port: number, id: string, token: string | null) {
  const frames: any[] = [];
  const headers = token ? { authorization: `Bearer ${token}` } : {};
  const ws = new WebSocket(`ws://127.0.0.1:${port}/session/${id}`, { headers });
  ws.on("message", (d: Buffer) => frames.push(JSON.parse(d.toString("utf8"))));
  return { ws, frames };
}

test("claude WS: attach → user → deltas → permission → result", async (t) => {
  const { app, port, token } = await bootApp();
  t.after(() => app.close());

  const create = await app.inject({
    method: "POST",
    url: "/sessions",
    headers: { authorization: `Bearer ${token}` },
    payload: { project_id: "p_ok", kind: "claude" },
  });
  const id = create.json().id;

  const { ws, frames } = connect(port, id, token);
  await new Promise<void>((res) => ws.on("open", () => res()));
  await waitFor(() => frames.some((f) => f.t === "history")); // history on attach

  // Exercise the interactive gate over the wire (auto-allow is the default).
  ws.send(JSON.stringify({ t: "auto_allow", on: false }));
  ws.send(JSON.stringify({ t: "user", text: "hi" }));
  await waitFor(() => frames.some((f) => f.t === "permission_request"));
  ws.send(JSON.stringify({ t: "permission", toolUseID: "tu1", allow: true }));
  await waitFor(() => frames.some((f) => f.t === "result"));

  const types = frames.map((f) => f.t);
  assert.ok(types.includes("init"));
  assert.ok(frames.some((f) => f.t === "delta" && f.text === "Hi"));
  assert.ok(types.includes("tool_use"));
  assert.equal(frames.find((f) => f.t === "assistant").text, "ok");
  ws.close();
});

test("claude WS: initialPrompt primes the first turn atomically (proposal 15)", async (t) => {
  const { app, port, token, db } = await bootApp();
  t.after(() => app.close());

  const create = await app.inject({
    method: "POST",
    url: "/sessions",
    headers: { authorization: `Bearer ${token}` },
    payload: { project_id: "p_ok", kind: "claude", initialPrompt: "review the diff" },
  });
  const id = create.json().id;
  // Stored on the row until the SDK starts (no client post-connect send needed).
  assert.equal((db.prepare("SELECT initial_prompt FROM sessions WHERE id=?").get(id) as any).initial_prompt, "review the diff");

  const { ws, frames } = connect(port, id, token);
  await new Promise<void>((res) => ws.on("open", () => res()));
  // The primed turn drives the SDK with NO client `user` frame — auto-allow
  // (default on) approves the tool and the turn runs through to `result`.
  await waitFor(() => frames.some((f) => f.t === "result"));
  const history = frames.find((f) => f.t === "history");
  assert.ok(history.messages.some((m: any) => m.role === "user" && m.content === "review the diff"));
  // Consumed: cleared so a reattach / daemon restart never re-sends it.
  assert.equal((db.prepare("SELECT initial_prompt FROM sessions WHERE id=?").get(id) as any).initial_prompt, null);
  ws.close();
});

test("native WS: an openai model routes to NativeSession and streams over the wire (ADR 0008)", async (t) => {
  const saved = process.env.VIBE_GATEWAY_MODELS;
  process.env.VIBE_GATEWAY_MODELS = JSON.stringify([{ id: "gpt-4o", provider: "openai" }]);
  const db = openDb(":memory:");
  const app = await buildApp(db, noTmux, new Map(), fakeQuery, fakeStreamText);
  await app.listen({ host: "127.0.0.1", port: 0 });
  const port = (app.server.address() as AddressInfo).port;
  t.after(() => {
    app.close();
    if (saved === undefined) delete process.env.VIBE_GATEWAY_MODELS;
    else process.env.VIBE_GATEWAY_MODELS = saved;
  });
  const { token } = (
    await app.inject({ method: "POST", url: "/pair", payload: { code: createPairingCode(db), device_name: "t" } })
  ).json();
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES (?,?,?,?)").run("p_ok", REPO_DIR, "vm", "unknown");

  const create = await app.inject({
    method: "POST",
    url: "/sessions",
    headers: { authorization: `Bearer ${token}` },
    payload: { project_id: "p_ok", kind: "claude", model: "gpt-4o" },
  });
  const id = create.json().id;

  const { ws, frames } = connect(port, id, token);
  await new Promise<void>((res) => ws.on("open", () => res()));
  await waitFor(() => frames.some((f) => f.t === "history"));
  ws.send(JSON.stringify({ t: "user", text: "hi" }));
  await waitFor(() => frames.some((f) => f.t === "result"));

  assert.equal(frames.find((f) => f.t === "init").model, "gpt-4o");
  assert.ok(frames.some((f) => f.t === "delta" && f.text === "Yo"));
  assert.equal(frames.find((f) => f.t === "assistant").text, "Yo");
  ws.close();
});

// discover.ts + transcript-import.ts: a row discovered from an external `claude`
// CLI transcript backfills history and flips to 'live' on its first attach.
test("claude WS: first attach to a discovered session backfills history and resumes", async (t) => {
  const claudeRoot = mkdtempSync(join(tmpdir(), "vibe-claude-"));
  const prev = process.env.VIBE_CLAUDE_PROJECTS_DIR;
  process.env.VIBE_CLAUDE_PROJECTS_DIR = claudeRoot;
  t.after(() => {
    rmSync(claudeRoot, { recursive: true, force: true });
    if (prev === undefined) delete process.env.VIBE_CLAUDE_PROJECTS_DIR;
    else process.env.VIBE_CLAUDE_PROJECTS_DIR = prev;
  });

  const transcriptDir = join(claudeRoot, encodeProjectPath(REPO_DIR));
  mkdirSync(transcriptDir, { recursive: true });
  writeFileSync(
    join(transcriptDir, "claude-xyz.jsonl"),
    JSON.stringify({ type: "user", timestamp: "t1", message: { content: "from the CLI" } }) + "\n",
  );

  const { app, port, token, db } = await bootApp();
  t.after(() => app.close());
  db.prepare(
    "INSERT INTO sessions (id, project_id, kind, claude_session_id, status, created_at) VALUES (?,?,?,?,?,?)",
  ).run("s_disc", "p_ok", "claude", "claude-xyz", "stale", new Date().toISOString());

  const { ws, frames } = connect(port, "s_disc", token);
  await new Promise<void>((res) => ws.on("open", () => res()));
  await waitFor(() => frames.some((f) => f.t === "history"));

  const history = frames.find((f) => f.t === "history");
  assert.ok(history.messages.some((m: any) => m.role === "user" && m.content === "from the CLI"));
  assert.equal(frames.find((f) => f.t === "init").claudeSessionId, "claude-xyz"); // fakeQuery echoes this session id
  assert.equal((db.prepare("SELECT status FROM sessions WHERE id = ?").get("s_disc") as any).status, "live");
  ws.close();
});

test("claude WS: non-claude / missing session → 4404", async (t) => {
  const { app, port, token } = await bootApp();
  t.after(() => app.close());
  const code = await new Promise<number>((res) => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/session/s_ghost`, { headers: { authorization: `Bearer ${token}` } });
    ws.on("close", (c) => res(c));
    ws.on("error", () => {});
  });
  assert.equal(code, 4404);
});

test("claude WS: unauthenticated upgrade rejected", async (t) => {
  const { app, port } = await bootApp();
  t.after(() => app.close());
  const rejected = await new Promise<boolean>((res) => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/session/whatever`); // no token
    ws.on("open", () => res(false));
    ws.on("error", () => res(true));
    ws.on("unexpected-response", () => res(true));
  });
  assert.equal(rejected, true);
});

test("claude WS: resuming a non-live row respects the live cap", async (t) => {
  process.env.VIBE_MAX_CLAUDE = "1";
  const { app, port, token, db } = await bootApp();
  t.after(() => {
    delete process.env.VIBE_MAX_CLAUDE;
    return app.close();
  });
  const ins = db.prepare("INSERT INTO sessions (id, project_id, kind, claude_session_id, status, created_at) VALUES (?,?,?,?,?,?)");
  ins.run("s_live", "p_ok", "claude", "c-live", "live", new Date().toISOString());
  ins.run("s_old", "p_ok", "claude", "c-old", "stale", new Date().toISOString());

  const frames: any[] = [];
  const code = await new Promise<number>((res) => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/session/s_old`, { headers: { authorization: `Bearer ${token}` } });
    ws.on("message", (d: Buffer) => frames.push(JSON.parse(d.toString("utf8"))));
    ws.on("close", (c) => res(c));
  });
  assert.equal(code, 4429);
  assert.equal(frames[0]?.t, "error");
  assert.equal((db.prepare("SELECT status FROM sessions WHERE id = 's_old'").get() as any).status, "stale");
});
