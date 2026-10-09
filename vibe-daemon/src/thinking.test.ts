// Thinking blocks (gap analysis, M9 spike): the daemon asks for summarized thinking,
// streams thinking_delta, and persists the final block as a `thinking` history row.
// Real-SDK shapes are from src/spike-thinking.ts; here a fake SDK replays them.

import test from "node:test";
import assert from "node:assert/strict";
import { openDb } from "./db.js";
import { ClaudeSession } from "./claude.js";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
async function waitFor(fn: () => boolean, ms = 1500) {
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

function run(thinkingText: string, opts: { env?: string } = {}) {
  const seen: { options?: any } = {};
  const queryFn = (params: { prompt: AsyncIterable<any>; options: any }) => {
    if (!params.options?.canUseTool) return (async function* () {})();
    seen.options = params.options;
    return (async function* () {
      yield { type: "system", subtype: "init", session_id: "c1", model: "m" };
      await params.prompt[Symbol.asyncIterator]().next();
      const ev = (delta: any) => ({ type: "stream_event", event: { type: "content_block_delta", delta } });
      yield { type: "stream_event", event: { type: "content_block_start", content_block: { type: "thinking" } } };
      if (thinkingText) {
        yield ev({ type: "thinking_delta", thinking: thinkingText.slice(0, 5) });
        yield ev({ type: "thinking_delta", thinking: thinkingText.slice(5) });
      } else {
        yield ev({ type: "thinking_delta", thinking: "" }); // omitted display: empty deltas
      }
      yield ev({ type: "signature_delta", signature: "sig" });
      yield { type: "stream_event", event: { type: "content_block_start", content_block: { type: "text" } } };
      yield ev({ type: "text_delta", text: "Answer" });
      yield {
        type: "assistant",
        message: { content: [{ type: "thinking", thinking: thinkingText, signature: "sig" }, { type: "text", text: "Answer" }] },
      };
      yield { type: "result", subtype: "success", total_cost_usd: 0 };
    })();
  };
  const db = openDb(":memory:");
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES ('p','/tmp','p','unknown')").run();
  db.prepare("INSERT INTO sessions (id, project_id, kind, status, created_at) VALUES ('s','p','claude','live',?)").run(new Date().toISOString());
  const prev = process.env.VIBE_SHOW_THINKING;
  if (opts.env !== undefined) process.env.VIBE_SHOW_THINKING = opts.env;
  const ws = fakeWs();
  const s = new ClaudeSession(db, "s", "/tmp", queryFn as any);
  s.attach(ws);
  s.start();
  if (prev === undefined) delete process.env.VIBE_SHOW_THINKING;
  else process.env.VIBE_SHOW_THINKING = prev;
  s.pushUser("hi");
  return { db, ws, seen, done: () => waitFor(() => ws.frames.some((f: any) => f.t === "result")) };
}

test("asks the SDK for summarized adaptive thinking by default", async () => {
  const r = run("reasoning here");
  await r.done();
  assert.deepEqual(r.seen.options.thinking, { type: "adaptive", display: "summarized" });
});

test("VIBE_SHOW_THINKING=0 keeps the old behaviour (no thinking option)", async () => {
  for (const off of ["0", "false", "off"]) {
    const r = run("x", { env: off });
    await r.done();
    assert.equal(r.seen.options.thinking, undefined, off);
  }
});

test("thinking_delta streams as thinking_delta frames, then one final thinking frame before the answer", async () => {
  const r = run("I should compute this carefully.");
  await r.done();
  const deltas = r.ws.frames.filter((f: any) => f.t === "thinking_delta").map((f: any) => f.text);
  assert.equal(deltas.join(""), "I should compute this carefully.");
  const types = r.ws.frames.map((f: any) => f.t);
  const finalThinking = r.ws.frames.find((f: any) => f.t === "thinking");
  assert.equal(finalThinking.text, "I should compute this carefully.");
  assert.ok(types.indexOf("thinking") < types.indexOf("assistant"), "thinking comes before the answer");
});

test("the final thinking block is persisted as a `thinking` row, in order, and replays in history", async () => {
  const r = run("deep thoughts");
  await r.done();
  const rows = r.db.prepare("SELECT role, content FROM messages WHERE session_id='s' ORDER BY rowid").all() as any[];
  assert.deepEqual(rows.map((x) => x.role), ["user", "thinking", "assistant", "result"]);
  assert.equal(rows[1].content, "deep thoughts");
  const ws2 = fakeWs();
  const s = new ClaudeSession(r.db, "s", "/tmp", (() => (async function* () {})()) as any);
  s.attach(ws2);
  const hist = ws2.frames.find((f: any) => f.t === "history");
  assert.ok(hist.messages.some((m: any) => m.role === "thinking" && m.content === "deep thoughts"));
});

test("empty (omitted) thinking produces no frames and no rows", async () => {
  const r = run("");
  await r.done();
  assert.equal(r.ws.frames.some((f: any) => f.t === "thinking" || f.t === "thinking_delta"), false);
  assert.equal((r.db.prepare("SELECT COUNT(*) n FROM messages WHERE role='thinking'").get() as any).n, 0);
});
