// Live model switch (gap analysis #8): `set_model` frame -> Query.setModel, Claude
// engine only. Fake SDK; the real setModel is covered by the e2e noted in the doc.

import { REPO_DIR } from "./test-paths.js";
import test from "node:test";
import assert from "node:assert/strict";
import { WebSocket } from "ws";
import type { AddressInfo } from "node:net";
import { openDb } from "./db.js";
import { buildApp } from "./app.js";
import { createPairingCode } from "./auth.js";
import { ClaudeSession } from "./claude.js";

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

function make(opts: { refuse?: boolean; model?: string | null } = {}) {
  const calls: (string | undefined)[] = [];
  const queryFn = (params: { prompt: AsyncIterable<any>; options: any }) => {
    if (!params.options?.canUseTool) return (async function* () {})();
    const gen: any = (async function* () {
      yield { type: "system", subtype: "init", session_id: "c", model: "m" };
      for await (const _ of params.prompt) yield { type: "result", subtype: "success", total_cost_usd: 0 };
    })();
    gen.setModel = async (m?: string) => {
      if (opts.refuse) throw new Error("unknown model");
      calls.push(m);
    };
    return gen;
  };
  const db = openDb(":memory:");
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES ('p','/tmp','p','unknown')").run();
  db.prepare("INSERT INTO sessions (id, project_id, kind, status, created_at, model) VALUES ('s','p','claude','live',?,?)").run(new Date().toISOString(), opts.model ?? null);
  const ws = fakeWs();
  const s = new ClaudeSession(db, "s", "/tmp", queryFn as any, undefined, opts.model ?? null);
  s.attach(ws);
  s.start();
  const modelRow = () => (db.prepare("SELECT model FROM sessions WHERE id='s'").get() as any).model;
  return { db, ws, s, calls, modelRow };
}

test("attach tells the client the current model and that it can be switched", () => {
  const { ws } = make({ model: "claude-sonnet-5-5" });
  assert.deepEqual(ws.frames.find((f: any) => f.t === "model"), { t: "model", model: "claude-sonnet-5-5", canSwitch: true });
});

test("setModel: SDK told, row updated, frame sent, audited", async () => {
  const { s, ws, calls, modelRow, db } = make({ model: "claude-sonnet-5-5" });
  assert.equal(await s.setModel("claude-opus-4-7", "dev1"), true);
  assert.deepEqual(calls, ["claude-opus-4-7"]);
  assert.equal(modelRow(), "claude-opus-4-7");
  assert.deepEqual(ws.frames.filter((f: any) => f.t === "model").pop(), { t: "model", model: "claude-opus-4-7", canSwitch: true });
  assert.deepEqual(db.prepare("SELECT kind, device_id, detail FROM events WHERE kind='session.model'").get(), {
    kind: "session.model", device_id: "dev1", detail: "s:claude-opus-4-7",
  });
});

test("setModel refuses native-provider ids, junk, and a no-op — nothing changes", async () => {
  const { s, calls, modelRow } = make({ model: "claude-sonnet-5-5" });
  for (const bad of ["openai:gpt-4o", "google:gemini-2.5-pro", "ollama:llama3", "", "   ", "has space", "a\nb", "x".repeat(129), "claude-sonnet-5-5"]) {
    assert.equal(await s.setModel(bad), false, JSON.stringify(bad));
  }
  assert.deepEqual(calls, []);
  assert.equal(modelRow(), "claude-sonnet-5-5");
});

test("if the SDK rejects the model, the session keeps its old one", async () => {
  const { s, modelRow, ws } = make({ model: "claude-sonnet-5-5", refuse: true });
  assert.equal(await s.setModel("nonsense-model"), false);
  assert.equal(modelRow(), "claude-sonnet-5-5");
  assert.equal(ws.frames.filter((f: any) => f.t === "model").length, 1, "only the attach-time frame");
});

test("a stopped session ignores setModel", async () => {
  const { s, calls } = make();
  s.stop();
  assert.equal(await s.setModel("claude-opus-4-7"), false);
  assert.deepEqual(calls, []);
});

test("WS: a set_model frame reaches the session; a bad model gets no change", async (t) => {
  const calls: (string | undefined)[] = [];
  const queryFn = (params: { prompt: AsyncIterable<any>; options: any }) => {
    if (!params.options?.canUseTool) return (async function* () {})();
    const gen: any = (async function* () {
      yield { type: "system", subtype: "init", session_id: "c", model: "m" };
      for await (const _ of params.prompt) yield { type: "result", subtype: "success", total_cost_usd: 0 };
    })();
    gen.setModel = async (m?: string) => void calls.push(m);
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
  await waitFor(() => frames.some((f) => f.t === "model"));
  ws.send(JSON.stringify({ t: "set_model", model: "openai:gpt-4o" }));
  ws.send(JSON.stringify({ t: "set_model", model: 42 }));
  ws.send(JSON.stringify({ t: "set_model", model: "claude-opus-4-7" }));
  await waitFor(() => frames.filter((f) => f.t === "model").length >= 2);
  assert.deepEqual(calls, ["claude-opus-4-7"], "only the valid switch reached the SDK");
  assert.equal(frames.filter((f) => f.t === "model").pop().model, "claude-opus-4-7");
  ws.close();
});

test("a synthetic string-content user/assistant message does not kill the session (regression: setModel echo)", async () => {
  // Real SDK: Query.setModel() makes the CLI emit a `user` message whose content is the
  // STRING "<local-command-stdout>Set model to …</local-command-stdout>". The daemon used
  // to call .filter on it, throw out of consume(), and end the session.
  const queryFn = (params: { prompt: AsyncIterable<any>; options: any }) => {
    if (!params.options?.canUseTool) return (async function* () {})();
    return (async function* () {
      yield { type: "system", subtype: "init", session_id: "c", model: "m" };
      for await (const _ of params.prompt) {
        yield { type: "user", message: { role: "user", content: "<local-command-stdout>Set model to haiku</local-command-stdout>" } };
        yield { type: "assistant", message: { content: "a string, not blocks" } };
        yield { type: "user", message: { role: "user" } }; // no content at all
        yield { type: "user" }; // no message at all
        yield { type: "assistant", message: { content: [{ type: "text", text: "still alive" }] } };
        yield { type: "result", subtype: "success", total_cost_usd: 0 };
      }
    })();
  };
  const db = openDb(":memory:");
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES ('p','/tmp','p','unknown')").run();
  db.prepare("INSERT INTO sessions (id, project_id, kind, status, created_at) VALUES ('s','p','claude','live',?)").run(new Date().toISOString());
  const ws = fakeWs();
  const s = new ClaudeSession(db, "s", "/tmp", queryFn as any);
  s.attach(ws);
  s.start();
  s.pushUser("one");
  await waitFor(() => ws.frames.some((f: any) => f.t === "result"));
  assert.equal(ws.frames.some((f: any) => f.t === "error"), false, "no error frame");
  assert.ok(ws.frames.some((f: any) => f.t === "assistant" && f.text === "still alive"));
  s.pushUser("two"); // the loop is still consuming
  await waitFor(() => ws.frames.filter((f: any) => f.t === "result").length === 2);
});
