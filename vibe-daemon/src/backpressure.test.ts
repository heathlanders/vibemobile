// Proposal 69 R10: a slow phone must not grow daemon memory without bound.
import test from "node:test";
import assert from "node:assert/strict";
import { openDb } from "./db.js";
import { ClaudeSession } from "./claude.js";
import { pipePty, WS_HIGH_WATER } from "./backpressure.js";

function slowWs(buffered: number) {
  const frames: any[] = [];
  return { OPEN: 1, readyState: 1, bufferedAmount: buffered, frames, send: (s: string) => frames.push(JSON.parse(s)), on() {}, ping() {}, close() {} };
}

test("chat: stream deltas are dropped while the socket is backed up; final frames are not", async () => {
  const db = openDb(":memory:");
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES ('p','/tmp','p','unknown')").run();
  db.prepare("INSERT INTO sessions (id, project_id, kind, status, created_at) VALUES ('s1','p','claude','live','t')").run();
  const q = (params: { prompt: AsyncIterable<any> }) =>
    (async function* () {
      yield { type: "system", subtype: "init", session_id: "c", model: "m" };
      await params.prompt[Symbol.asyncIterator]().next();
      yield { type: "stream_event", event: { type: "content_block_delta", delta: { type: "text_delta", text: "Hi" } } };
      yield { type: "assistant", message: { content: [{ type: "text", text: "Hi there" }] } };
      yield { type: "result", subtype: "success", total_cost_usd: 0 };
    })();
  const s = new ClaudeSession(db, "s1", "/tmp", q as any);
  const ws = slowWs(WS_HIGH_WATER + 1);
  s.attach(ws as any);
  s.start();
  s.pushUser("go");
  for (let i = 0; i < 200 && !ws.frames.some((f) => f.t === "result"); i++) await new Promise((r) => setTimeout(r, 5));
  assert.ok(!ws.frames.some((f) => f.t === "delta"), "deltas dropped");
  assert.equal(ws.frames.find((f) => f.t === "assistant")?.text, "Hi there", "the full text still arrives");
  assert.ok(ws.frames.some((f) => f.t === "result"));
  s.stop();
});

test("pty: output pauses above the high-water mark and resumes once drained", () => {
  let onData!: (d: string) => void;
  const calls: string[] = [];
  const term = { onData: (cb: (d: string) => void) => (onData = cb), pause: () => calls.push("pause"), resume: () => calls.push("resume") };
  const pending: (() => void)[] = [];
  const ws = { OPEN: 1, readyState: 1, bufferedAmount: 0, send: (_d: string, cb: () => void) => pending.push(cb) };
  pipePty(term, ws as any);
  onData("a");
  assert.deepEqual(calls, []);
  ws.bufferedAmount = WS_HIGH_WATER + 1;
  onData("b");
  assert.deepEqual(calls, ["pause"]);
  ws.bufferedAmount = 0;
  pending.forEach((cb) => cb());
  assert.deepEqual(calls, ["pause", "resume"]);
});
