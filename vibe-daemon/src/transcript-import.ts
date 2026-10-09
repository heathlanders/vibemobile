// Backfill `messages` from a Claude Code CLI transcript (~/.claude/projects/
// <encoded-path>/<session-id>.jsonl) the FIRST time the daemon attaches to a
// session it discovered rather than created (discover.ts). Mirrors the role/
// shape rules claude.ts's live `handle()` uses for 'assistant' text/tool_use
// (claude.ts:330-341) and 'user' tool_result folding (claude.ts:343-354,
// attachToolResult) — but folds a tool_result onto its tool_use row in memory,
// since the whole file is available up front, instead of a DB round trip.
//
// Image blocks in a tool_result are stored as attachments (proposal 33, same
// gate as claude.ts). Images in user turns (pasted into the CLI) still aren't.

import { readFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import type { DB } from "./db.js";
import { toolResultImages } from "./attachments.js";
import { composeTitle, projectPrefix, titleOnFirstUserTurn } from "./titler.js";

type Row = { role: "user" | "assistant" | "tool"; content: string | null; tool_json: string | null; ts: string };

// A tool_result block's content is a string or an array of content blocks
// (same shape claude.ts's toolResultText handles).
export function toolResultText(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content.map((c) => (typeof c === "string" ? c : ((c as { text?: string })?.text ?? ""))).join("");
  }
  return "";
}

// Parse one CLI transcript into ordered `messages` rows. Exported for tests;
// importTranscript() is the DB-writing wrapper below. `images` stores a
// tool_result's image blocks and returns their attachment ids.
export function parseTranscript(raw: string, images: (content: unknown) => string[] = () => []): Row[] {
  const rows: Row[] = [];
  const toolRowByUseId = new Map<string, Row>();
  for (const line of raw.split("\n")) {
    if (!line.trim()) continue;
    let msg: any;
    try {
      msg = JSON.parse(line);
    } catch {
      continue;
    }
    // Sub-agent (Task tool) sidechains aren't part of the main conversation the
    // live path ever streams to handle() — skip, same as a real attach would show.
    if (msg.isSidechain) continue;
    if (msg.type !== "user" && msg.type !== "assistant") continue;
    const ts = typeof msg.timestamp === "string" ? msg.timestamp : new Date().toISOString();
    const content = msg.message?.content;
    const blocks: any[] = Array.isArray(content) ? content : [];
    const plainText = typeof content === "string" ? content : null;

    if (msg.type === "assistant") {
      const text = plainText ?? blocks.filter((b) => b.type === "text").map((b) => b.text).join("");
      if (text) rows.push({ role: "assistant", content: text, tool_json: null, ts });
      for (const b of blocks.filter((b) => b.type === "tool_use")) {
        const row: Row = { role: "tool", content: null, tool_json: JSON.stringify({ id: b.id, name: b.name, input: b.input }), ts };
        rows.push(row);
        toolRowByUseId.set(b.id, row);
      }
    } else {
      const text = plainText ?? blocks.filter((b) => b.type === "text").map((b) => b.text).join("");
      if (text) rows.push({ role: "user", content: text, tool_json: null, ts });
      for (const b of blocks.filter((b) => b.type === "tool_result")) {
        const row = toolRowByUseId.get(b.tool_use_id);
        if (!row || !row.tool_json) continue;
        const j = JSON.parse(row.tool_json);
        j.result = toolResultText(b.content);
        j.isError = !!b.is_error;
        const ids = images(b.content);
        if (ids.length) j.images = ids;
        row.tool_json = JSON.stringify(j);
      }
    }
  }
  return rows;
}

// The CLI's own session name: the last `{"type":"ai-title","aiTitle":…}` line.
// Undocumented format (ADR 0012) — null when absent, callers fall back to the
// first-prompt heuristic.
export function aiTitleOf(line: string): string | null {
  if (!line.includes('"ai-title"')) return null;
  try {
    const j = JSON.parse(line);
    return j.type === "ai-title" && typeof j.aiTitle === "string" && j.aiTitle.trim() ? j.aiTitle.trim() : null;
  } catch {
    return null;
  }
}

export function latestAiTitle(raw: string): string | null {
  let title: string | null = null;
  for (const line of raw.split("\n")) title = aiTitleOf(line) ?? title;
  return title;
}

// Apply the CLI's title unless the user pinned one (title_auto=0 with a title).
// Returns the stored title when it changed, else null.
export function applyAiTitle(db: DB, sessionId: string, cwd: string, aiTitle: string): string | null {
  const title = composeTitle(projectPrefix(cwd), aiTitle);
  const info = db
    .prepare("UPDATE sessions SET title = ?, title_auto = 1 WHERE id = ? AND (title_auto = 1 OR title IS NULL) AND title IS NOT ?")
    .run(title, sessionId, title);
  return info.changes ? title : null;
}

// Read the transcript, insert its rows into `messages`, and title the session
// via the existing auto-titler (same as a live first turn). No-op (fail-soft)
// if the file is gone — the discovery row still resumes via claude_session_id.
export function importTranscript(db: DB, sessionId: string, cwd: string, jsonlPath: string): void {
  let raw: string;
  try {
    raw = readFileSync(jsonlPath, "utf8");
  } catch {
    return;
  }
  importTranscriptText(db, sessionId, cwd, raw);
}

// Same, from already-read transcript text (external.ts's mirror reads the file
// itself so it knows the byte offset to tail from).
export function importTranscriptText(db: DB, sessionId: string, cwd: string, raw: string): void {
  const rows = parseTranscript(raw, (c) => toolResultImages(db, sessionId, c));
  const ai = latestAiTitle(raw);
  if (!rows.length) {
    if (ai) applyAiTitle(db, sessionId, cwd, ai);
    return;
  }
  const insert = db.prepare("INSERT INTO messages (id, session_id, role, content, tool_json, ts) VALUES (?,?,?,?,?,?)");
  const tx = db.transaction((rs: Row[]) => {
    for (const r of rs) insert.run(randomUUID(), sessionId, r.role, r.content, r.tool_json, r.ts);
  });
  tx(rows);
  const firstUser = rows.find((r) => r.role === "user" && r.content);
  if (firstUser?.content) titleOnFirstUserTurn(db, sessionId, cwd, firstUser.content, () => {});
  if (ai) applyAiTitle(db, sessionId, cwd, ai); // the CLI's name beats the first-prompt guess
}
