// Shape checks for incoming WS frames (proposal 72 Q3).
import test from "node:test";
import assert from "node:assert/strict";
import { parseClientFrame, parseResize } from "./ws-frames.js";

test("parseClientFrame keeps known shapes and drops the rest", () => {
  assert.deepEqual(parseClientFrame('{"t":"user","text":"hi"}'), { t: "user", text: "hi" });
  assert.deepEqual(parseClientFrame('{"t":"set_effort","effort":null}'), { t: "set_effort", effort: null });
  assert.equal(parseClientFrame('{"t":"dialog_response","dialogId":"d","completed":true,"result":{"a":1}}')?.t, "dialog_response");
  for (const bad of ["", "not json", "null", "5", "[]", '"user"', "{}", '{"t":"nope"}', '{"t":"user","text":5}',
    '{"t":"user","text":"x","images":[1]}', '{"t":"permission","toolUseID":"a","allow":"yes"}', '{"t":"mode"}']) {
    assert.equal(parseClientFrame(bad), null, bad);
  }
});

test("parseResize accepts integer sizes in 1..1000 only", () => {
  assert.deepEqual(parseResize('{"cols":100,"rows":30}'), { cols: 100, rows: 30 });
  for (const bad of ["x", "null", "{}", '{"cols":0,"rows":5}', '{"cols":1.5,"rows":5}', '{"cols":"9","rows":5}', '{"cols":1001,"rows":5}']) {
    assert.equal(parseResize(bad), null, bad);
  }
});
