// External-session discovery verification (CLAUDE.md §4). Fixture
// ~/.claude/projects/<encoded>/ dir with .jsonl files → correct sessions rows.

import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { openDb } from "./db.js";
import { discoverExternalSessions, encodeProjectPath, isInternalTranscript, purgeInternalTranscriptRows } from "./discover.js";

function seedProject(db: ReturnType<typeof openDb>, path: string) {
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES (?,?,?,?)").run("p1", path, "p", "unknown");
  return { id: "p1", path };
}

test("encodeProjectPath replaces every / with -", () => {
  assert.equal(encodeProjectPath("/home/user/vibemobile"), "-home-user-vibemobile");
});

test("discovers new external sessions and registers them stale", () => {
  const claudeRoot = mkdtempSync(join(tmpdir(), "vibe-claude-"));
  const projectPath = "/home/user/somewhere";
  const transcriptDir = join(claudeRoot, encodeProjectPath(projectPath));
  mkdirSync(transcriptDir, { recursive: true });
  writeFileSync(
    join(transcriptDir, "sess-a.jsonl"),
    JSON.stringify({ type: "user", timestamp: "2026-01-01T00:00:00.000Z", message: { role: "user", content: "hi" } }) + "\n",
  );
  writeFileSync(join(transcriptDir, "sess-b.jsonl"), JSON.stringify({ type: "queue-operation" }) + "\n");
  // A non-transcript dir alongside the .jsonl files (sidechain/scratch) must be ignored.
  mkdirSync(join(transcriptDir, "sess-a"));

  try {
    const db = openDb(":memory:");
    const project = seedProject(db, projectPath);
    discoverExternalSessions(db, project, claudeRoot);

    const rows = db.prepare("SELECT claude_session_id, status, created_at FROM sessions ORDER BY claude_session_id").all() as any[];
    // sess-b has no user turn → not listed
    assert.equal(rows.length, 1);
    assert.deepEqual(rows.map((r) => r.claude_session_id), ["sess-a"]);
    assert.ok(rows.every((r) => r.status === "stale"));
    assert.equal(rows.find((r) => r.claude_session_id === "sess-a").created_at, "2026-01-01T00:00:00.000Z");
  } finally {
    rmSync(claudeRoot, { recursive: true, force: true });
  }
});

test("skips sessions already known to the daemon", () => {
  const claudeRoot = mkdtempSync(join(tmpdir(), "vibe-claude-"));
  const projectPath = "/home/user/somewhere";
  const transcriptDir = join(claudeRoot, encodeProjectPath(projectPath));
  mkdirSync(transcriptDir, { recursive: true });
  writeFileSync(join(transcriptDir, "sess-a.jsonl"), JSON.stringify({ type: "user" }) + "\n");

  try {
    const db = openDb(":memory:");
    const project = seedProject(db, projectPath);
    db.prepare(
      "INSERT INTO sessions (id, project_id, kind, claude_session_id, status, created_at) VALUES (?,?,?,?,?,?)",
    ).run("s_existing", "p1", "claude", "sess-a", "live", new Date().toISOString());

    discoverExternalSessions(db, project, claudeRoot);

    const rows = db.prepare("SELECT id FROM sessions").all();
    assert.equal(rows.length, 1, "no duplicate row for an already-known session id");
  } finally {
    rmSync(claudeRoot, { recursive: true, force: true });
  }
});

test("skips transcripts dismissed in the app", () => {
  const claudeRoot = mkdtempSync(join(tmpdir(), "vibe-claude-"));
  const projectPath = "/home/user/somewhere";
  const transcriptDir = join(claudeRoot, encodeProjectPath(projectPath));
  mkdirSync(transcriptDir, { recursive: true });
  writeFileSync(join(transcriptDir, "sess-a.jsonl"), JSON.stringify({ type: "user" }) + "\n");
  writeFileSync(join(transcriptDir, "sess-b.jsonl"), JSON.stringify({ type: "user" }) + "\n");

  try {
    const db = openDb(":memory:");
    const project = seedProject(db, projectPath);
    db.prepare("INSERT INTO dismissed_transcripts (claude_session_id, dismissed_at) VALUES (?,?)").run(
      "sess-a",
      new Date().toISOString(),
    );

    discoverExternalSessions(db, project, claudeRoot);

    const rows = db.prepare("SELECT claude_session_id FROM sessions").all() as any[];
    assert.deepEqual(rows.map((r) => r.claude_session_id), ["sess-b"]);
  } finally {
    rmSync(claudeRoot, { recursive: true, force: true });
  }
});

test("missing transcript dir is a no-op, not an error", () => {
  const db = openDb(":memory:");
  const project = seedProject(db, "/home/user/never-scanned");
  assert.doesNotThrow(() => discoverExternalSessions(db, project, "/no/such/claude/root"));
  assert.equal((db.prepare("SELECT COUNT(*) AS n FROM sessions").get() as any).n, 0);
});

test("titles a discovered session from the CLI's latest ai-title", () => {
  const claudeRoot = mkdtempSync(join(tmpdir(), "vibe-claude-"));
  const projectPath = "/home/user/somewhere";
  const transcriptDir = join(claudeRoot, encodeProjectPath(projectPath));
  mkdirSync(transcriptDir, { recursive: true });
  writeFileSync(
    join(transcriptDir, "sess-a.jsonl"),
    [
      { type: "user", timestamp: "2026-01-01T00:00:00.000Z", message: { role: "user", content: "/clear" } },
      { type: "ai-title", aiTitle: "Old name", sessionId: "sess-a" },
      { type: "ai-title", aiTitle: "Fix login bug", sessionId: "sess-a" },
    ]
      .map((l) => JSON.stringify(l))
      .join("\n") + "\n",
  );
  try {
    const db = openDb(":memory:");
    discoverExternalSessions(db, seedProject(db, projectPath), claudeRoot);
    const row = db.prepare("SELECT title, title_auto FROM sessions").get() as any;
    assert.equal(row.title, "somewhere · Fix login bug");
    assert.equal(row.title_auto, 1);
  } finally {
    rmSync(claudeRoot, { recursive: true, force: true });
  }
});

// Titler / Improve-prompt one-shots used to persist a transcript under the
// project's dir, which discovery then listed as a session.
const userLine = (content: unknown) => JSON.stringify({ type: "user", message: { role: "user", content } });
const TITLER = userLine([{ type: "text", text: "Summarize this coding request as a chat title: 5 words max.\n\n<request>\nhi\n</request>" }]);
const IMPROVE = userLine("<prompt>\nfix the bug\n</prompt>");

test("isInternalTranscript: one-shot titler/improve only, not a resumed one", () => {
  assert.equal(isInternalTranscript(TITLER + "\n"), true);
  assert.equal(isInternalTranscript(IMPROVE + "\n"), true);
  assert.equal(isInternalTranscript(TITLER + "\n" + userLine("why did this show up?") + "\n"), false);
  assert.equal(isInternalTranscript(userLine("Summarize this repo") + "\n"), false);
  // A tool_result is not a user turn.
  assert.equal(isInternalTranscript(IMPROVE + "\n" + userLine([{ type: "tool_result", content: "x" }]) + "\n"), true);
});

test("discovery skips internal transcripts; startup purge drops already-listed ones", () => {
  const claudeRoot = mkdtempSync(join(tmpdir(), "vibe-claude-"));
  const projectPath = "/home/user/somewhere";
  const dir = join(claudeRoot, encodeProjectPath(projectPath));
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "title.jsonl"), TITLER + "\n");
  writeFileSync(join(dir, "real.jsonl"), userLine("hi") + "\n");
  try {
    const db = openDb(":memory:");
    const project = seedProject(db, projectPath);
    discoverExternalSessions(db, project, claudeRoot);
    const ids = () => (db.prepare("SELECT claude_session_id FROM sessions ORDER BY 1").all() as any[]).map((r) => r.claude_session_id);
    assert.deepEqual(ids(), ["real"]);

    // A row registered before the filter existed → purged + dismissed.
    db.prepare("INSERT INTO sessions (id, project_id, kind, claude_session_id, status, created_at) VALUES (?,?,?,?,?,?)").run(
      "s_old", "p1", "claude", "title", "stale", new Date().toISOString(),
    );
    assert.equal(purgeInternalTranscriptRows(db, claudeRoot), 1);
    assert.deepEqual(ids(), ["real"]);
    assert.ok(db.prepare("SELECT 1 FROM dismissed_transcripts WHERE claude_session_id = 'title'").get());
  } finally {
    rmSync(claudeRoot, { recursive: true, force: true });
  }
});
