// TurnStatus (proposal 32): the chat status line's server half.

import test from "node:test";
import assert from "node:assert/strict";
import { TurnStatus } from "./turn-status.js";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

function make(heartbeatMs = 10_000) {
  const frames: any[] = [];
  const s = new TurnStatus((f) => frames.push(f), heartbeatMs);
  return { s, frames };
}

test("idle frame before any turn; set() is ignored outside a turn", () => {
  const { s, frames } = make();
  assert.deepEqual(s.frame(), { t: "status", running: false });
  s.set("writing");
  assert.equal(frames.length, 0);
});

test("begin → phase changes emit once each → end", () => {
  const { s, frames } = make();
  s.begin();
  s.begin(); // mid-turn send folds in: no second start
  s.set("tool", "Bash");
  s.set("tool", "Bash"); // unchanged: no frame
  s.set("writing");
  s.end();
  s.end(); // idempotent
  assert.deepEqual(
    frames.map((f) => [f.running, f.phase, f.tool]),
    [
      [true, "thinking", undefined],
      [true, "tool", "Bash"],
      [true, "writing", undefined],
      [false, undefined, undefined],
    ],
  );
  assert.equal(typeof frames[0].elapsedMs, "number");
  assert.equal(typeof frames[0].idleMs, "number");
});

test("wait → resume restores the phase the turn was in", () => {
  const { s, frames } = make();
  s.begin();
  s.set("tool", "Edit");
  s.wait();
  s.wait(); // a second card while already waiting: no frame
  s.resume();
  s.end();
  assert.deepEqual(
    frames.map((f) => [f.phase, f.tool]),
    [
      ["thinking", undefined],
      ["tool", "Edit"],
      ["waiting", undefined],
      ["tool", "Edit"],
      [undefined, undefined],
    ],
  );
});

test("heartbeat runs only while a turn is running; idleMs grows without activity", async () => {
  const { s, frames } = make(15);
  s.begin();
  await sleep(80);
  const beats = frames.length - 1;
  assert.ok(beats >= 2, `expected heartbeats, got ${beats}`);
  assert.ok(frames.at(-1).idleMs >= 30);
  s.touch();
  assert.ok((s.frame().idleMs as number) < 15);
  s.end();
  const n = frames.length;
  await sleep(50);
  assert.equal(frames.length, n, "no heartbeats after end");
});
