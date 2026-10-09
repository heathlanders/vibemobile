import test from "node:test";
import assert from "node:assert/strict";
import { capHistory, shrinkRow, HISTORY_MAX_ROWS } from "./history.js";

const row = (i: number, extra: object = {}) => ({ id: `m${i}`, role: "assistant", content: `msg ${i}`, tool_json: null, ts: String(i), ...extra });

test("small histories pass through untouched", () => {
  const rows = [row(1), row(2)];
  assert.deepEqual(capHistory(rows), { rows, omitted: 0 });
});

test("keeps the newest rows, oldest first, and reports how many were left out", () => {
  const rows = Array.from({ length: HISTORY_MAX_ROWS + 50 }, (_, i) => row(i));
  const r = capHistory(rows);
  assert.equal(r.rows.length, HISTORY_MAX_ROWS);
  assert.equal(r.omitted, 50);
  assert.equal(r.rows[0].id, "m50");
  assert.equal(r.rows.at(-1)!.id, `m${HISTORY_MAX_ROWS + 49}`);
});

test("a huge tool result and input are truncated but stay valid JSON", () => {
  const big = "x".repeat(50_000);
  const t = shrinkRow({ role: "tool", content: null, tool_json: JSON.stringify({ id: "t1", name: "Bash", input: { command: big }, result: big, isError: false }) });
  const j = JSON.parse(t.tool_json!);
  assert.equal(j.name, "Bash");
  assert.ok(j.result.length < 4_100 && j.input.command.length < 4_100);
  assert.match(j.result, /truncated/);
});

test("an unparseable oversized tool_json is dropped; a small one is kept", () => {
  assert.equal(shrinkRow({ role: "tool", tool_json: "{" + "y".repeat(9_000) }).tool_json, null);
  assert.equal(shrinkRow({ role: "tool", tool_json: "{bad" }).tool_json, "{bad");
});

test("the byte budget bounds the frame even when every row is large", () => {
  const rows = Array.from({ length: 300 }, (_, i) => row(i, { content: "z".repeat(15_000) }));
  const bytes = JSON.stringify(capHistory(rows).rows).length;
  assert.ok(bytes < 1_700_000, `frame was ${bytes}`);
  assert.ok(capHistory(rows).omitted > 0);
});

test("a single oversized newest row is still delivered (truncated)", () => {
  const r = capHistory([row(1, { content: "q".repeat(100_000) })]);
  assert.equal(r.rows.length, 1);
  assert.ok(r.rows[0].content!.length < 20_100);
});
