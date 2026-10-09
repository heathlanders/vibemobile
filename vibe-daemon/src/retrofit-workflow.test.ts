// Retrofit (ADR 0028): additive only — lists gaps, creates missing files, never touches existing ones.

import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { planRetrofit, applyRetrofit } from "./retrofit-workflow.js";

const tmp = () => mkdtempSync(join(tmpdir(), "retro-"));

test("an empty dir lacks every standard file; apply creates them with the project name", () => {
  const d = tmp();
  try {
    const r = planRetrofit(d);
    assert.ok(r.missing.some((f) => f.path === "docs/WORKFLOW.md"));
    applyRetrofit(d, "demo", r.missing, "2026-10-08");
    assert.match(readFileSync(join(d, "CLAUDE.md"), "utf8"), /CLAUDE\.md — demo/);
    assert.ok(existsSync(join(d, "docs/handoffs/.gitkeep")));
    assert.equal(planRetrofit(d).missing.length, 0);
  } finally {
    rmSync(d, { recursive: true, force: true });
  }
});

test("existing files are never modified; a PLAN.md without Milestones is only reported", () => {
  const d = tmp();
  try {
    writeFileSync(join(d, "CLAUDE.md"), "MINE");
    writeFileSync(join(d, "PLAN.md"), "# my plan\nno sections\n");
    mkdirSync(join(d, "docs"));
    const r = planRetrofit(d);
    assert.ok(!r.missing.some((f) => f.path === "CLAUDE.md" || f.path === "PLAN.md"));
    assert.equal(r.notes.length, 1);
    applyRetrofit(d, "demo", r.missing);
    assert.equal(readFileSync(join(d, "CLAUDE.md"), "utf8"), "MINE");
    assert.equal(readFileSync(join(d, "PLAN.md"), "utf8"), "# my plan\nno sections\n");
  } finally {
    rmSync(d, { recursive: true, force: true });
  }
});

test("an existing docs dir doesn't need its .gitkeep", () => {
  const d = tmp();
  try {
    mkdirSync(join(d, "docs/spikes"), { recursive: true });
    const r = planRetrofit(d);
    assert.ok(!r.missing.some((f) => f.path === "docs/spikes/.gitkeep"));
    assert.ok(r.missing.some((f) => f.path === "docs/handoffs/.gitkeep"));
  } finally {
    rmSync(d, { recursive: true, force: true });
  }
});
