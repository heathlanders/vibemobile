// Discover Claude Code sessions started outside the daemon — e.g. `claude` CLI
// run directly over SSH — and register them as attachable `sessions` rows
// (docs/protocols/session-rest.md). Read-only scan of the CLI's own transcript
// dir (~/.claude/projects/<encoded-path>/*.jsonl); never writes there.

import { readdirSync, readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import type { DB } from "./db.js";
import { newId } from "./sessions.js";
import { applyAiTitle, latestAiTitle } from "./transcript-import.js";
import { TITLE_PROMPT_HEAD } from "./titler.js";

// Claude Code names a project's transcript dir by replacing every "/" in the
// resolved absolute path with "-" (verified against a real ~/.claude/projects/,
// e.g. /home/user/vibemobile -> -home-user-vibemobile).
export function encodeProjectPath(absPath: string): string {
  return resolve(absPath).replace(/\//g, "-");
}

// Overridable so tests (and an unusual CLAUDE_CONFIG_DIR setup) don't have to
// touch the real ~/.claude/projects.
export function defaultClaudeProjectsRoot(): string {
  return process.env.VIBE_CLAUDE_PROJECTS_DIR ?? join(homedir(), ".claude", "projects");
}

// The transcript's own first-line timestamp, else the file's mtime.
function createdAtOf(path: string, raw: string): string {
  try {
    const firstLine = raw.split("\n").find((l) => l.trim());
    const ts = firstLine ? JSON.parse(firstLine)?.timestamp : undefined;
    if (typeof ts === "string") return ts;
  } catch {
    // fall through to mtime
  }
  return new Date(statSync(path).mtimeMs).toISOString();
}

// A transcript with no user turn (CLI opened and closed, /clear leftovers) has
// nothing to show — don't list it.
const hasUserTurn = (raw: string) => /"type":\s*"user"/.test(raw);

// A transcript the daemon's own one-shot SDK calls wrote (auto-titler, Improve
// prompt) before they ran with `persistSession: false`: exactly one real user
// turn, and it is that call's prompt. A transcript the user later resumed and
// typed into has more turns and stays listed.
export function isInternalTranscript(raw: string): boolean {
  const texts: string[] = [];
  for (const line of raw.split("\n")) {
    if (!line.includes('"user"')) continue;
    let e: any;
    try {
      e = JSON.parse(line);
    } catch {
      continue;
    }
    if (e?.type !== "user" || e.isMeta) continue;
    const c = e.message?.content;
    if (Array.isArray(c) && c.some((b: any) => b?.type === "tool_result")) continue;
    texts.push(typeof c === "string" ? c : Array.isArray(c) ? c.map((b: any) => b?.text ?? "").join("") : "");
  }
  if (texts.length !== 1) return false;
  const t = texts[0];
  return t.startsWith(TITLE_PROMPT_HEAD) || (t.startsWith("<prompt>\n") && t.endsWith("\n</prompt>"));
}

// Scan a project's Claude Code transcript dir for session ids the daemon
// doesn't have a row for yet, and register one per new id. Rows start
// status='stale', NOT 'live' — sessions.ts's live cap (maxLive) is checked at
// POST /sessions time by counting status='live' rows, and a project can easily
// have more old transcripts than the cap. session-ws.ts's getOrStart flips a
// row to 'live' when it's actually attached, same as a fresh daemon-created row.
export function discoverExternalSessions(
  db: DB,
  project: { id: string; path: string },
  claudeProjectsRoot: string = defaultClaudeProjectsRoot(),
  // The CLI push hook (hook.ts) fires for a session whose first turn may not be
  // flushed to disk yet, so it must still be able to register an empty one.
  includeEmpty = false,
): void {
  const dir = join(claudeProjectsRoot, encodeProjectPath(project.path));
  let files: string[];
  try {
    files = readdirSync(dir).filter((f) => f.endsWith(".jsonl"));
  } catch {
    return; // no external transcripts for this project — not an error
  }
  const known = new Set(
    (
      db
        .prepare("SELECT claude_session_id FROM sessions WHERE project_id = ? AND claude_session_id IS NOT NULL")
        .all(project.id) as { claude_session_id: string }[]
    ).map((r) => r.claude_session_id),
  );
  // Deleted in the app: the .jsonl stays (CLI resume still works), but don't re-list it.
  for (const r of db.prepare("SELECT claude_session_id FROM dismissed_transcripts").all() as { claude_session_id: string }[]) {
    known.add(r.claude_session_id);
  }
  const insert = db.prepare(
    "INSERT INTO sessions (id, project_id, kind, claude_session_id, status, created_at) VALUES (?,?,?,?,?,?)",
  );
  for (const file of files) {
    const sessionId = file.slice(0, -".jsonl".length);
    if (known.has(sessionId)) continue;
    let raw: string;
    try {
      raw = readFileSync(join(dir, file), "utf8");
    } catch {
      continue;
    }
    if (!includeEmpty && !hasUserTurn(raw)) continue;
    if (isInternalTranscript(raw)) continue;
    const id = newId();
    insert.run(id, project.id, "claude", sessionId, "stale", createdAtOf(join(dir, file), raw));
    const ai = latestAiTitle(raw);
    if (ai) applyAiTitle(db, id, project.path, ai);
  }
}

// One-time cleanup for rows discovery registered before the filter above:
// dismiss (so it never re-lists) and delete every never-attached ('stale') row
// whose transcript is an internal one-shot. Transcript files are left alone.
export function purgeInternalTranscriptRows(db: DB, claudeProjectsRoot: string = defaultClaudeProjectsRoot()): number {
  const rows = db
    .prepare(
      `SELECT s.id, s.claude_session_id, p.path FROM sessions s JOIN projects p ON p.id = s.project_id
       WHERE s.kind = 'claude' AND s.status = 'stale' AND s.claude_session_id IS NOT NULL`,
    )
    .all() as { id: string; claude_session_id: string; path: string }[];
  const dismiss = db.prepare("INSERT OR IGNORE INTO dismissed_transcripts (claude_session_id, dismissed_at) VALUES (?,?)");
  const del = db.prepare("DELETE FROM sessions WHERE id = ?");
  let n = 0;
  for (const r of rows) {
    let raw: string;
    try {
      raw = readFileSync(join(claudeProjectsRoot, encodeProjectPath(r.path), `${r.claude_session_id}.jsonl`), "utf8");
    } catch {
      continue;
    }
    if (!isInternalTranscript(raw)) continue;
    db.transaction(() => {
      dismiss.run(r.claude_session_id, new Date().toISOString());
      del.run(r.id);
    })();
    n++;
  }
  return n;
}
