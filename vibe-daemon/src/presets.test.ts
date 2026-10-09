// presets.ts (ADR 0016) — preset table + cached install detection (fake detector).

import test from "node:test";
import assert from "node:assert/strict";
import { PRESETS, clearPresetCache, installedPresets, presetById } from "./presets.js";

test("installedPresets keeps table order, filters to detected commands, and caches", async () => {
  clearPresetCache();
  let calls = 0;
  const detect = async (cmds: string[]) => {
    calls++;
    assert.deepEqual(cmds, PRESETS.map((p) => p.command)); // only table literals are probed
    return ["aider", "codex"];
  };
  assert.deepEqual((await installedPresets(detect)).map((p) => p.id), ["codex", "aider"]);
  await installedPresets(detect);
  assert.equal(calls, 1);
  clearPresetCache();
});

test("presetById only knows table ids", () => {
  assert.equal(presetById("gemini")?.command, "gemini");
  assert.equal(presetById("bash -c id"), undefined);
});
