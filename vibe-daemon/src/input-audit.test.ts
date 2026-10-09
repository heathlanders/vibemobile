import test from "node:test";
import assert from "node:assert/strict";
import { openDb } from "./db.js";
import { inputAudit } from "./input-audit.js";

test("inputAudit: one start, one end with byte count; silent when nothing typed", () => {
  const db = openDb(":memory:");
  const idle = inputAudit(db, "terminal.input", "d1", "s0");
  idle.end();
  const a = inputAudit(db, "terminal.input", "d1", "s1");
  a.add(5);
  a.add(0);
  a.add(7);
  a.end();
  const ev = db.prepare("SELECT kind, device_id, detail FROM events ORDER BY rowid").all() as any[];
  assert.deepEqual(ev.map((e) => [e.kind, e.device_id]), [["terminal.input.start", "d1"], ["terminal.input.end", "d1"]]);
  assert.match(ev[1].detail, /^s1:bytes=12:secs=\d+$/);
});
