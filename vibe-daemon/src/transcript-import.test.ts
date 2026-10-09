// Transcript backfill verification (CLAUDE.md §4). parseTranscript is pure and
// exercised directly; importTranscript is checked against a real in-memory DB.

import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { openDb } from "./db.js";
import { parseTranscript, importTranscript, importTranscriptText } from "./transcript-import.js";

const line = (obj: unknown) => JSON.stringify(obj);

test("parseTranscript: plain user text + assistant text/tool_use/tool_result fold", () => {
  const raw = [
    line({ type: "user", timestamp: "t1", message: { role: "user", content: "hi" } }),
    line({
      type: "assistant",
      timestamp: "t2",
      message: { content: [{ type: "text", text: "ok" }, { type: "tool_use", id: "tu1", name: "Read", input: { file: "a" } }] },
    }),
    line({
      type: "user",
      timestamp: "t3",
      message: { content: [{ type: "tool_result", tool_use_id: "tu1", content: "file contents", is_error: false }] },
    }),
  ].join("\n");

  const rows = parseTranscript(raw);
  assert.equal(rows.length, 3);
  assert.deepEqual(
    rows.map((r) => r.role),
    ["user", "assistant", "tool"],
  );
  assert.equal(rows[0].content, "hi");
  assert.equal(rows[1].content, "ok");
  const tool = JSON.parse(rows[2].tool_json!);
  assert.deepEqual(tool, { id: "tu1", name: "Read", input: { file: "a" }, result: "file contents", isError: false });
});

test("parseTranscript: ignores non-user/assistant lines and sidechains", () => {
  const raw = [
    line({ type: "queue-operation", operation: "enqueue" }),
    line({ type: "attachment", attachment: { content: "hook output" } }),
    line({ type: "user", isSidechain: true, message: { content: "subagent turn" } }),
    line({ type: "user", timestamp: "t1", message: { content: "real turn" } }),
  ].join("\n");

  const rows = parseTranscript(raw);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].content, "real turn");
});

test("parseTranscript: skips a tool_use with no matching text, and unparsable lines", () => {
  const raw = ["not json", line({ type: "assistant", message: { content: [{ type: "thinking", thinking: "hmm" }] } })].join("\n");
  assert.deepEqual(parseTranscript(raw), []);
});

test("importTranscript: backfills messages in order and titles the session", () => {
  const dir = mkdtempSync(join(tmpdir(), "vibe-transcript-"));
  const jsonlPath = join(dir, "sess-a.jsonl");
  writeFileSync(
    jsonlPath,
    [
      line({ type: "user", timestamp: "t1", message: { content: "please read the readme" } }),
      line({ type: "assistant", timestamp: "t2", message: { content: [{ type: "text", text: "done" }] } }),
    ].join("\n"),
  );

  try {
    const db = openDb(":memory:");
    db.prepare("INSERT INTO projects (id, path, name, type) VALUES (?,?,?,?)").run("p1", "/home/user/x", "x", "unknown");
    db.prepare("INSERT INTO sessions (id, project_id, kind, claude_session_id, status, created_at) VALUES (?,?,?,?,?,?)").run(
      "s1",
      "p1",
      "claude",
      "sess-a",
      "stale",
      new Date().toISOString(),
    );

    importTranscript(db, "s1", "/home/user/x", jsonlPath);

    const rows = db.prepare("SELECT role, content, ts FROM messages WHERE session_id = ? ORDER BY ts").all("s1") as any[];
    assert.deepEqual(
      rows.map((r) => [r.role, r.content]),
      [
        ["user", "please read the readme"],
        ["assistant", "done"],
      ],
    );
    const title = (db.prepare("SELECT title FROM sessions WHERE id = ?").get("s1") as any).title;
    assert.ok(title, "auto-titler fired off the imported first user turn");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("importTranscript: missing file is a fail-soft no-op", () => {
  const db = openDb(":memory:");
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES (?,?,?,?)").run("p1", "/home/user/x", "x", "unknown");
  db.prepare("INSERT INTO sessions (id, project_id, kind, claude_session_id, status, created_at) VALUES (?,?,?,?,?,?)").run(
    "s1",
    "p1",
    "claude",
    "sess-a",
    "stale",
    new Date().toISOString(),
  );
  assert.doesNotThrow(() => importTranscript(db, "s1", "/home/user/x", "/no/such/file.jsonl"));
  assert.equal((db.prepare("SELECT COUNT(*) AS n FROM messages").get() as any).n, 0);
});

// Proposal 33: a CLI transcript's tool_result image blocks (Read on a PNG) become
// attachments through the same gate as the live engine — ≤4 per result, junk
// dropped + audited. The mirror wipes and re-imports on every attach, so a second
// import must reuse the stored blobs, not duplicate them.
test("importTranscriptText: tool_result images → attachments, capped, deduped on re-import", () => {
  const db = openDb(":memory:");
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES (?,?,?,?)").run("p1", "/home/user/x", "x", "unknown");
  db.prepare("INSERT INTO sessions (id, project_id, kind, claude_session_id, status, created_at) VALUES (?,?,?,?,?,?)").run(
    "s1", "p1", "claude", "sess-a", "stale", new Date().toISOString(),
  );
  const png = (n: number) =>
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, n]).toString("base64");
  const img = (data: string) => ({ type: "image", source: { type: "base64", media_type: "image/png", data } });
  const raw = [
    line({ type: "assistant", timestamp: "t1", message: { content: [{ type: "tool_use", id: "tu1", name: "Read", input: { file_path: "a.png" } }] } }),
    line({
      type: "user",
      timestamp: "t2",
      message: {
        content: [
          {
            type: "tool_result",
            tool_use_id: "tu1",
            content: [img(Buffer.from("nope").toString("base64")), img(png(1)), img(png(2)), img(png(3)), img(png(4)), img(png(5))],
          },
        ],
      },
    }),
  ].join("\n");

  importTranscriptText(db, "s1", "/home/user/x", raw);
  const ids = () => {
    const row = db.prepare("SELECT tool_json FROM messages WHERE session_id = 's1' AND role = 'tool'").get() as any;
    return JSON.parse(row.tool_json).images as string[];
  };
  const first = ids();
  assert.equal(first.length, 4, "capped at 4");
  const count = () => (db.prepare("SELECT COUNT(*) AS n FROM attachments WHERE session_id = 's1'").get() as any).n;
  assert.equal(count(), 4);
  const audit = db.prepare("SELECT detail FROM events WHERE kind = 'attachment.reject'").get() as any;
  assert.match(audit.detail, /^s1:tool_unsupported_type:4$/);

  db.prepare("DELETE FROM messages WHERE session_id = 's1'").run(); // what Mirror does per attach
  importTranscriptText(db, "s1", "/home/user/x", raw);
  assert.deepEqual(ids(), first, "same ids on re-import");
  assert.equal(count(), 4, "no duplicate blobs");
});
