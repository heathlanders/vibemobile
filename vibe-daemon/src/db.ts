// SQLite layer (PLAN §3). Opens the daemon DB and bootstraps the schema.
// M1 = auth tables (devices, pairing_codes, events) + the project/session
// catalog (projects, sessions); messages / prompts land with their milestones.
// WAL + foreign keys on. Pass ":memory:" for tests.

import Database from "better-sqlite3";
import { FOUNDATIONS_FILES } from "./scaffold-seed.js";
import { migrateLedgerToDeltas } from "./spend.js";

export type DB = Database.Database;

const SCHEMA = `
CREATE TABLE IF NOT EXISTS devices (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  token_hash  TEXT NOT NULL UNIQUE,   -- sha256(opaque token); token itself never stored
  paired_at   TEXT NOT NULL,
  last_seen   TEXT,
  fcm_token   TEXT
);

CREATE TABLE IF NOT EXISTS pairing_codes (
  code_hash   TEXT PRIMARY KEY,       -- sha256(code); plaintext shown once in server terminal
  expires_at  TEXT NOT NULL,
  used        INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS events (    -- audit log (security #5)
  id          TEXT PRIMARY KEY,
  kind        TEXT NOT NULL,
  device_id   TEXT,
  detail      TEXT,
  ts          TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS projects (  -- scanner catalog (scanner.ts, PLAN §3)
  id          TEXT PRIMARY KEY,
  path        TEXT NOT NULL UNIQUE,   -- absolute dir; upsert key
  name        TEXT,
  type        TEXT,                   -- flutter | laravel | node | unknown
  git_branch  TEXT,
  last_active TEXT
);

CREATE TABLE IF NOT EXISTS sessions (  -- terminal/claude sessions (M2+, PLAN §3)
  id                TEXT PRIMARY KEY,
  project_id        TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  kind              TEXT NOT NULL CHECK (kind IN ('terminal','claude')),
  claude_session_id TEXT,            -- null until first SDK init (kind=claude)
  title             TEXT,
  status            TEXT NOT NULL DEFAULT 'live',  -- live | dead | stale
  created_at        TEXT NOT NULL,
  initial_prompt    TEXT,            -- first turn to prime on attach, then cleared (proposal 15)
  tags              TEXT,            -- comma-separated grouping labels (proposal 12)
  total_cost_usd    REAL NOT NULL DEFAULT 0,  -- running spend, accumulated per result (proposal 03)
  title_auto        INTEGER NOT NULL DEFAULT 0 -- title came from the auto-titler (ADR 0009)
);

CREATE TABLE IF NOT EXISTS messages (  -- claude transcript cache (M3, PLAN §3)
  id          TEXT PRIMARY KEY,
  session_id  TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  role        TEXT NOT NULL,         -- user | assistant | tool | result
  content     TEXT,                  -- rendered text
  tool_json   TEXT,                  -- tool_use / tool_result / result detail
  ts          TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS settings ( -- daemon-wide settings (settings.ts, ADR 0026); value is JSON
  key        TEXT PRIMARY KEY,
  value      TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  updated_by TEXT
);

CREATE TABLE IF NOT EXISTS schedules ( -- unattended prompts (schedule.ts, proposal 44)
  id              TEXT PRIMARY KEY,
  project_id      TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  title           TEXT NOT NULL,
  prompt          TEXT NOT NULL,
  mode            TEXT NOT NULL DEFAULT 'ask',   -- ask | auto | plan (session mode of the run)
  model           TEXT,
  kind            TEXT NOT NULL,                 -- once | daily
  time            TEXT,                          -- HH:MM, server local time (daily)
  days            TEXT,                          -- CSV of 0-6 (Sunday=0); null = every day
  run_at          TEXT,                          -- ISO instant (once)
  enabled         INTEGER NOT NULL DEFAULT 1,
  next_run_at     TEXT,                          -- ISO UTC; null once a 'once' schedule has run
  last_run_at     TEXT,
  last_status     TEXT,                          -- started | missed | waiting | skipped: … | failed: …
  last_session_id TEXT,
  created_at      TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS dismissed_transcripts ( -- CLI transcripts deleted in the app; discover.ts skips them
  claude_session_id TEXT PRIMARY KEY,
  dismissed_at      TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS attachments ( -- image input for claude turns (proposal 16)
  id          TEXT PRIMARY KEY,
  session_id  TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  media_type  TEXT NOT NULL,          -- sniffed from magic bytes, not the client
  data        BLOB NOT NULL,          -- the image bytes (≤ VIBE_MAX_ATTACH_BYTES)
  created_at  TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS prompts (   -- reusable prompt library (M4, PLAN §3)
  id          TEXT PRIMARY KEY,
  title       TEXT NOT NULL,
  body        TEXT NOT NULL,          -- may contain {{var}} placeholders
  tags        TEXT,                   -- comma-separated
  project_id  TEXT REFERENCES projects(id) ON DELETE CASCADE,  -- null = global
  vars_json   TEXT,                   -- per-variable defaults/labels
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS notes (     -- per-project notes / TODOs (proposal 31)
  id          TEXT PRIMARY KEY,
  project_id  TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  text        TEXT NOT NULL,
  done        INTEGER NOT NULL DEFAULT 0,
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_notes_project ON notes(project_id);

CREATE TABLE IF NOT EXISTS usage_events ( -- token spend per model per turn (spend.ts)
  id            TEXT PRIMARY KEY,
  session_id    TEXT,                 -- no FK: spend history outlives deleted sessions
  project_id    TEXT,
  provider      TEXT NOT NULL,
  model         TEXT NOT NULL,
  input_tokens  INTEGER NOT NULL DEFAULT 0,  -- uncached input
  output_tokens INTEGER NOT NULL DEFAULT 0,
  cache_read    INTEGER NOT NULL DEFAULT 0,
  cache_write   INTEGER NOT NULL DEFAULT 0,
  cost_usd      REAL NOT NULL DEFAULT 0,     -- anthropic on Max: API-equivalent, not billed
  ts            TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_usage_ts ON usage_events(ts);

-- The Agent SDK's result.modelUsage / total_cost_usd are CUMULATIVE for the whole conversation (even
-- across a resume in a new process — M16 spike). This is the last cumulative reading per session and
-- model, so each turn can be recorded as a DELTA (spend.ts recordCumulative). model='__total__' holds
-- the session's total cost.
CREATE TABLE IF NOT EXISTS usage_cumulative (
  session_id    TEXT NOT NULL,
  model         TEXT NOT NULL,
  input_tokens  INTEGER NOT NULL DEFAULT 0,
  output_tokens INTEGER NOT NULL DEFAULT 0,
  cache_read    INTEGER NOT NULL DEFAULT 0,
  cache_write   INTEGER NOT NULL DEFAULT 0,
  cost_usd      REAL NOT NULL DEFAULT 0,
  PRIMARY KEY (session_id, model)
);

CREATE TABLE IF NOT EXISTS scaffolds ( -- foundation templates (proposal 17)
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  description TEXT,
  files_json  TEXT NOT NULL,          -- JSON: [{ "path": "CLAUDE.md", "body": "..." }, ...]
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL
);
`;

// Ship-seeded global prompt (PLAN §3): the 4 Karpathy guidelines from CLAUDE.md —
// the canonical cross-project prompt the library exists to manage. Fixed id →
// INSERT OR IGNORE seeds it exactly once.
const WORK_PROMPTS: [string, string, string][] = [
  [
    "seed-work-handoff",
    "Write a handoff",
    "Write a Handoff for this session to docs/handoffs/YYYY-MM-DD-<slug>.md (see docs/WORKFLOW.md). Sections: State (branch, last commit, tests passing?), Done, Not done, Next step (one concrete action), Gotchas, Commands to resume. Carry unfinished task-list items forward; put unfinished scope back into the Roadmap in PLAN.md as Milestones. Commit it.",
  ],
  [
    "seed-work-resume",
    "Resume from handoff",
    "Start by reading CLAUDE.md, the open Milestones in PLAN.md, and the newest file in docs/handoffs/. Then tell me in a few lines where we left off and propose the next step. Do not start building until I agree.",
  ],
  [
    "seed-work-proposal",
    "Write a proposal",
    "Write a Proposal in docs/proposals/NN-<title>.md (next free number; see docs/WORKFLOW.md) for: <feature>. Include problem, approach, what it touches, risks, and open questions, with Status: idea. Add its row to docs/proposals/README.md. Do not build it.",
  ],
  [
    "seed-work-close-milestone",
    "Close out a milestone",
    "The milestone <name> is done. Tick it in PLAN.md, set its Proposal's status to shipped, add the .claude/docs-map.md row for the new surface, and write a Handoff if work remains. Show me the diff before committing.",
  ],
];

const SEED_KARPATHY_BODY = `Behavioral guidelines (Andrej Karpathy's LLM-coding observations):

1. Think Before Coding — don't assume, don't hide confusion, surface tradeoffs.
   State assumptions; if multiple interpretations exist, present them; if a
   simpler approach exists, say so; if unclear, stop and ask.

2. Simplicity First — the minimum code that solves the problem, nothing
   speculative. No features beyond what was asked, no abstractions for single-use
   code, no unrequested flexibility, no error handling for impossible scenarios.

3. Surgical Changes — touch only what you must; clean up only your own mess.
   Don't refactor what isn't broken; match existing style; every changed line
   should trace directly to the request.

4. Goal-Driven Execution — define success criteria and loop until verified.
   Turn tasks into verifiable goals ("add validation" → "write tests for invalid
   inputs, then make them pass") so you can loop independently.`;

// Always-on pack (proposal 61): Felix Rieseberg's "How to be more ambitious", tuned
// so ambition means depth and verification, never extra scope.
const SEED_AMBITION_BODY = `Ambition guidelines (Felix Rieseberg, "How to be more ambitious"):

- Altitude: before starting, say in one line what the user likely wants to happen
  after this task, and serve that. When a choice is needed, surface it as a
  decision with the strongest argument for each option.
- Depth: use professional-grade methods (real tests, profilers, databases,
  statistics), not approximations. Work from the rawest source available (logs,
  data, code), not summaries.
- Evidence: don't grade your own work. Show something external that proves it: a
  test run, real output, a measurement. If the data contradicts an assumption
  (the user's included), say so.
- Hard targets: if a target looks ambitious, treat it as achievable; explain what
  it would take rather than quietly lowering it.
- Range: name which discipline's methods fit the problem and apply them.

Ambition applies to depth and verification, never to scope: still change only
what was asked.`;

function seedPrompts(db: DB): void {
  const now = new Date().toISOString();
  // always_apply=1 (proposal 61): fresh DBs start with both packs on. Existing DBs keep
  // their row (INSERT OR IGNORE); migrate() switched Karpathy on once for them.
  const pack = db.prepare(
    `INSERT OR IGNORE INTO prompts (id, title, body, tags, project_id, vars_json, created_at, updated_at, always_apply)
     VALUES (?,?,?,?,?,?,?,?,1)`,
  );
  pack.run("seed-karpathy", "Karpathy guidelines", SEED_KARPATHY_BODY, "guidelines,global", null, null, now, now);
  pack.run("seed-ambition", "Ambition (Rieseberg)", SEED_AMBITION_BODY, "guidelines,global", null, null, now, now);
  // Work-standard prompts (ADR 0028, docs/WORKFLOW.md): fixed ids → seeded once, editable after.
  const ins = db.prepare(
    `INSERT OR IGNORE INTO prompts (id, title, body, tags, project_id, vars_json, created_at, updated_at)
     VALUES (?,?,?,?,?,?,?,?)`,
  );
  for (const [id, title, body] of WORK_PROMPTS) ins.run(id, title, body, "workflow,global", null, null, now, now);
}

// Ship-seeded scaffold (proposal 17): the generic foundations skeleton applied to
// new projects. Fixed id → INSERT OR IGNORE seeds it exactly once.
function seedScaffolds(db: DB): void {
  const now = new Date().toISOString();
  db.prepare(
    `INSERT OR IGNORE INTO scaffolds (id, name, description, files_json, created_at, updated_at)
     VALUES (?,?,?,?,?,?)`,
  ).run(
    "seed-foundations",
    "Foundations (generic)",
    "Generic CLAUDE.md + docs skeleton — the conventions this server is set up with.",
    JSON.stringify(FOUNDATIONS_FILES),
    now,
    now,
  );
  // A seed row that was never edited (updated_at = created_at) follows the shipped content;
  // an edited one is the user's and is left alone. (ADR 0028)
  db.prepare("UPDATE scaffolds SET files_json = ?, description = ? WHERE id = 'seed-foundations' AND updated_at = created_at AND files_json != ?").run(
    JSON.stringify(FOUNDATIONS_FILES),
    "Generic CLAUDE.md + docs skeleton — the conventions this server is set up with.",
    JSON.stringify(FOUNDATIONS_FILES),
  );
}

// Schema is declared with CREATE TABLE IF NOT EXISTS (no migration runner), so new
// columns on existing tables need an idempotent ALTER. Guard each on table_info.
function migrate(db: DB): void {
  const has = (table: string, col: string) =>
    (db.prepare(`PRAGMA table_info(${table})`).all() as { name: string }[]).some((c) => c.name === col);
  if (!has("sessions", "initial_prompt")) db.exec("ALTER TABLE sessions ADD COLUMN initial_prompt TEXT");
  if (!has("sessions", "tags")) db.exec("ALTER TABLE sessions ADD COLUMN tags TEXT");
  if (!has("sessions", "total_cost_usd")) db.exec("ALTER TABLE sessions ADD COLUMN total_cost_usd REAL NOT NULL DEFAULT 0");
  // Per-session model id (ADR 0007). null = the gateway/CLI default. The string is
  // an upstream model routed by the local Anthropic-compat gateway (src/gateway.ts).
  if (!has("sessions", "model")) db.exec("ALTER TABLE sessions ADD COLUMN model TEXT");
  // The title was written by the auto-titler (titler.ts, ADR 0009) and may still be
  // refined by it. A manual PATCH clears this, pinning the title for good. Existing
  // rows default to 0, so the titler never touches sessions that predate it.
  if (!has("sessions", "title_auto")) db.exec("ALTER TABLE sessions ADD COLUMN title_auto INTEGER NOT NULL DEFAULT 0");
  // Session mode (proposal 25): 'ask' | 'auto' | 'plan'. null = daemon default
  // (auto). Persisted so a reaped/restarted session resumes in the same mode.
  if (!has("sessions", "mode")) db.exec("ALTER TABLE sessions ADD COLUMN mode TEXT");
  // SDK uuid of a user message (ADR 0023): the daemon mints it, sends it as
  // SDKUserMessage.uuid, and Query.rewindFiles() takes it. Null for older rows /
  // other engines — those turns can't be rewound.
  if (!has("messages", "sdk_uuid")) db.exec("ALTER TABLE messages ADD COLUMN sdk_uuid TEXT");
  // Worktree-per-session (ADR 0022): where the session's isolated checkout lives,
  // its branch, and the commit it forked from (to tell "no new work" at delete time).
  if (!has("sessions", "worktree_path")) db.exec("ALTER TABLE sessions ADD COLUMN worktree_path TEXT");
  if (!has("sessions", "worktree_branch")) db.exec("ALTER TABLE sessions ADD COLUMN worktree_branch TEXT");
  if (!has("sessions", "base_ref")) db.exec("ALTER TABLE sessions ADD COLUMN base_ref TEXT");
  // Reasoning effort (proposal 39): 'low'|'medium'|'high'|'xhigh'|'max', null = the model's default.
  if (!has("sessions", "effort")) db.exec("ALTER TABLE sessions ADD COLUMN effort TEXT");
  // Prompt library usage (ADR 0018): "most used" sort.
  if (!has("prompts", "use_count")) db.exec("ALTER TABLE prompts ADD COLUMN use_count INTEGER NOT NULL DEFAULT 0");
  if (!has("prompts", "last_used_at")) db.exec("ALTER TABLE prompts ADD COLUMN last_used_at TEXT");
  // Always-apply prompts (proposal 61, ADR 0031). Switching Karpathy on happens only in the
  // branch that adds the column, so a user who later turns it off keeps it off.
  if (!has("prompts", "always_apply")) {
    db.exec("ALTER TABLE prompts ADD COLUMN always_apply INTEGER NOT NULL DEFAULT 0");
    db.exec("UPDATE prompts SET always_apply = 1 WHERE id = 'seed-karpathy'");
  }
  // ADR 0029: which device minted a code (NULL = the server terminal).
  if (!has("pairing_codes", "issued_by")) db.exec("ALTER TABLE pairing_codes ADD COLUMN issued_by TEXT");
  // The audit-log viewer (GET /events) pages by ts descending.
  db.exec("CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts)");
}

export function openDb(file = process.env.VIBE_DB ?? "vibe.db"): DB {
  const db = new Database(file);
  db.pragma("journal_mode = WAL");
  db.pragma("foreign_keys = ON");
  db.exec(SCHEMA);
  migrate(db);
  migrateLedgerToDeltas(db); // one-time: cumulative readings summed per turn → real per-turn deltas (spend.ts)
  seedPrompts(db);
  seedScaffolds(db);
  return db;
}
