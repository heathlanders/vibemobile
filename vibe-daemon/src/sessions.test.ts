// Session REST verification. Drives the real app via inject() against an
// in-memory DB and a FAKE tmux (no real sessions spawned). Covers validation,
// the M3-deferred claude path (501), and DELETE idempotency.

import { REPO_DIR } from "./test-paths.js";
import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { openDb } from "./db.js";
import { buildApp } from "./app.js";
import { createPairingCode } from "./auth.js";
import { encodeProjectPath } from "./discover.js";
import type { Tmux } from "./tmux.js";
import type { ClaudeRegistry } from "./claude.js";
import { clearPresetCache, installedPresets } from "./presets.js";

// In-memory fake: tracks which session ids "exist" in tmux. `live` is exposed so
// a test can evict a session out-of-band (simulating a reboot killing tmux).
function fakeTmux(): Tmux & { live: Set<string>; commands: Map<string, string | undefined> } {
  const live = new Set<string>();
  const commands = new Map<string, string | undefined>();
  return {
    live,
    commands,
    async ensureGlobals() {},
    async createSession(id, _cwd, command) {
      live.add(id);
      commands.set(id, command);
    },
    async hasSession(id) {
      return live.has(id);
    },
    async detachOthers() {},
    attach() {
      throw new Error("attach not used in REST tests");
    },
    async killSession(id) {
      live.delete(id);
    },
    async sweepStale() {},
  };
}

// p_ok's path below (REPO_DIR) is this very repo's real checkout,
// which has a real ~/.claude/projects transcript dir on a dev box. Point
// discovery (discover.ts) at a guaranteed-empty dir by default so tests stay
// hermetic; a test that wants to exercise discovery sets this env var itself
// (before calling setup()) and this default backs off.
function isolateFromRealClaudeProjects() {
  if (process.env.VIBE_CLAUDE_PROJECTS_DIR === undefined) {
    process.env.VIBE_CLAUDE_PROJECTS_DIR = "/nonexistent/vibe-test-claude-projects";
  }
}

async function setup() {
  isolateFromRealClaudeProjects();
  const db = openDb(":memory:");
  const tmux = fakeTmux();
  const registry: ClaudeRegistry = new Map();
  const app = await buildApp(db, tmux, registry);
  const { token } = (
    await app.inject({ method: "POST", url: "/pair", payload: { code: createPairingCode(db), device_name: "t" } })
  ).json();
  const auth = { authorization: `Bearer ${token}` };
  // A project inside the allowed roots (default /home/user) so POST can spawn there.
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES (?,?,?,?)").run(
    "p_ok",
    REPO_DIR,
    "vibemobile",
    "unknown",
  );
  return { db, app, auth, tmux, registry };
}

const post = (app: any, auth: any, body: unknown) =>
  app.inject({ method: "POST", url: "/sessions", headers: auth, payload: body });

test("POST /sessions requires project_id and kind", async () => {
  const { app, auth } = await setup();
  assert.equal((await post(app, auth, {})).statusCode, 400);
  assert.equal((await post(app, auth, { project_id: "p_ok" })).statusCode, 400);
});

test("POST /sessions rejects unknown project", async () => {
  const { app, auth } = await setup();
  assert.equal((await post(app, auth, { project_id: "nope", kind: "terminal" })).statusCode, 404);
});

test("POST /sessions rejects a project path outside the roots", async () => {
  const { db, app, auth } = await setup();
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES (?,?,?,?)").run("p_bad", "/etc", "etc", "unknown");
  assert.equal((await post(app, auth, { project_id: "p_bad", kind: "terminal" })).statusCode, 400);
});

test("POST /sessions kind=claude creates a row (no tmux)", async () => {
  const { app, auth, tmux } = await setup();
  const res = await post(app, auth, { project_id: "p_ok", kind: "claude" });
  assert.equal(res.statusCode, 201);
  assert.equal(res.json().kind, "claude");
  assert.equal(tmux.live.size, 0, "claude session does not create a tmux session");
});

test("POST /sessions rejects an unknown kind", async () => {
  const { app, auth } = await setup();
  assert.equal((await post(app, auth, { project_id: "p_ok", kind: "banana" })).statusCode, 400);
});

// ADR 0007 — model is stored on claude sessions and echoed back; ignored for terminal.
test("POST /sessions persists model for claude, ignores it for terminal", async () => {
  const { db, app, auth } = await setup();
  const claude = await post(app, auth, { project_id: "p_ok", kind: "claude", model: "gpt-4o" });
  assert.equal(claude.json().model, "gpt-4o");
  assert.equal((db.prepare("SELECT model FROM sessions WHERE id = ?").get(claude.json().id) as any).model, "gpt-4o");

  const term = await post(app, auth, { project_id: "p_ok", kind: "terminal", model: "gpt-4o" });
  assert.equal((db.prepare("SELECT model FROM sessions WHERE id = ?").get(term.json().id) as any).model, null);
});

// GET /models returns the picker registry. Force gateway mode with an operator list
// so the route reads the env (authoritative there) instead of hitting the live
// Anthropic Models API — keeps this unit test hermetic (no network). The direct-mode
// live-fetch + fallback path is covered in gateway.test.ts.
test("GET /models returns a model registry", async () => {
  const saved = { url: process.env.VIBE_GATEWAY_URL, models: process.env.VIBE_GATEWAY_MODELS };
  process.env.VIBE_GATEWAY_URL = "http://127.0.0.1:4000";
  process.env.VIBE_GATEWAY_MODELS = JSON.stringify([{ id: "claude-opus-4-7", label: "Opus 4.7", provider: "anthropic" }]);
  try {
    const { app, auth } = await setup();
    const res = await app.inject({ method: "GET", url: "/models", headers: auth });
    assert.equal(res.statusCode, 200);
    assert.ok(Array.isArray(res.json().models) && res.json().models.length >= 1);
  } finally {
    if (saved.url === undefined) delete process.env.VIBE_GATEWAY_URL;
    else process.env.VIBE_GATEWAY_URL = saved.url;
    if (saved.models === undefined) delete process.env.VIBE_GATEWAY_MODELS;
    else process.env.VIBE_GATEWAY_MODELS = saved.models;
  }
});

test("POST /sessions terminal creates a live session, GET lists it", async () => {
  const { app, auth } = await setup();
  const res = await post(app, auth, { project_id: "p_ok", kind: "terminal", title: "build" });
  assert.equal(res.statusCode, 201);
  const s = res.json();
  assert.match(s.id, /^s_[0-9a-f]{12}$/);
  assert.equal(s.status, "live");
  assert.equal(s.kind, "terminal");

  const list = await app.inject({ method: "GET", url: "/sessions?project_id=p_ok", headers: auth });
  assert.equal(list.json().length, 1);

  const one = await app.inject({ method: "GET", url: `/sessions/${s.id}`, headers: auth });
  assert.equal(one.json().status, "live"); // fake tmux still has it
});

test("GET /sessions/:id 404 for unknown", async () => {
  const { app, auth } = await setup();
  assert.equal((await app.inject({ method: "GET", url: "/sessions/s_missing", headers: auth })).statusCode, 404);
});

test("PATCH /sessions/:id renames the title", async () => {
  const { app, auth } = await setup();
  const { id } = (await post(app, auth, { project_id: "p_ok", kind: "terminal" })).json();
  const res = await app.inject({ method: "PATCH", url: `/sessions/${id}`, headers: auth, payload: { title: "build logs" } });
  assert.equal(res.statusCode, 200);
  assert.equal(res.json().title, "build logs");
  assert.equal((await app.inject({ method: "PATCH", url: "/sessions/s_missing", headers: auth, payload: { title: "x" } })).statusCode, 404);
});

test("PATCH title pins it against the auto-titler; tags alone don't (ADR 0009)", async () => {
  const { db, app, auth } = await setup();
  const { id } = (await post(app, auth, { project_id: "p_ok", kind: "claude" })).json();
  const autoFlag = () => (db.prepare("SELECT title_auto FROM sessions WHERE id = ?").get(id) as any).title_auto;

  db.prepare("UPDATE sessions SET title = 'auto · x', title_auto = 1 WHERE id = ?").run(id);
  await app.inject({ method: "PATCH", url: `/sessions/${id}`, headers: auth, payload: { tags: "review" } });
  assert.equal(autoFlag(), 1, "a tags-only PATCH leaves the title auto");

  await app.inject({ method: "PATCH", url: `/sessions/${id}`, headers: auth, payload: { title: "mine" } });
  assert.equal(autoFlag(), 0, "a manual rename pins the title");
});

test("PATCH /sessions/:id sets tags, normalized (proposal 12)", async () => {
  const { app, auth } = await setup();
  const { id } = (await post(app, auth, { project_id: "p_ok", kind: "claude" })).json();
  const res = await app.inject({
    method: "PATCH",
    url: `/sessions/${id}`,
    headers: auth,
    payload: { tags: " review , bug, review ,, " },
  });
  assert.equal(res.statusCode, 200);
  assert.equal(res.json().tags, "review,bug", "trimmed, de-blanked, de-duped");
  // Title untouched when only tags are sent.
  assert.equal(res.json().title, null);
  // Clearing tags stores null.
  const cleared = await app.inject({ method: "PATCH", url: `/sessions/${id}`, headers: auth, payload: { tags: "" } });
  assert.equal(cleared.json().tags, null);
});

test("GET /sessions/:id/messages?q= searches the transcript (proposal 10)", async () => {
  const { db, app, auth } = await setup();
  const { id } = (await post(app, auth, { project_id: "p_ok", kind: "claude" })).json();
  const ins = db.prepare("INSERT INTO messages (id, session_id, role, content, tool_json, ts) VALUES (?,?,?,?,?,?)");
  ins.run("m1", id, "user", "fix the failing test", null, "2026-01-01T00:00:00Z");
  ins.run("m2", id, "assistant", "the bug is in auth middleware", null, "2026-01-01T00:01:00Z");
  ins.run("m3", id, "assistant", "unrelated reply", null, "2026-01-01T00:02:00Z");

  const hits = (await app.inject({ method: "GET", url: `/sessions/${id}/messages?q=bug`, headers: auth })).json();
  assert.equal(hits.length, 1);
  assert.equal(hits[0].id, "m2");

  // No q → full transcript, newest first.
  const all = (await app.inject({ method: "GET", url: `/sessions/${id}/messages`, headers: auth })).json();
  assert.equal(all.length, 3);
  assert.equal(all[0].id, "m3");

  // Unknown session → 404.
  assert.equal((await app.inject({ method: "GET", url: "/sessions/s_missing/messages", headers: auth })).statusCode, 404);
});

test("DELETE /sessions/:id is idempotent (204 twice)", async () => {
  const { app, auth } = await setup();
  const { id } = (await post(app, auth, { project_id: "p_ok", kind: "terminal" })).json();
  assert.equal((await app.inject({ method: "DELETE", url: `/sessions/${id}`, headers: auth })).statusCode, 204);
  assert.equal((await app.inject({ method: "DELETE", url: `/sessions/${id}`, headers: auth })).statusCode, 204);
  // Row is gone after delete.
  assert.equal((await app.inject({ method: "GET", url: `/sessions/${id}`, headers: auth })).statusCode, 404);
});

test("DELETE /sessions/:id dismisses a claude transcript so discovery won't re-list it", async () => {
  const { db, app, auth } = await setup();
  db.prepare(
    "INSERT INTO sessions (id, project_id, kind, claude_session_id, status, created_at) VALUES (?,?,?,?,?,?)",
  ).run("s_cli", "p_ok", "claude", "sess-cli", "stale", new Date().toISOString());
  assert.equal((await app.inject({ method: "DELETE", url: "/sessions/s_cli", headers: auth })).statusCode, 204);
  const dismissed = db.prepare("SELECT claude_session_id FROM dismissed_transcripts").all() as any[];
  assert.deepEqual(dismissed.map((r) => r.claude_session_id), ["sess-cli"]);
});

test("POST /sessions/prune clears stale rows, keeps live, dismisses transcripts", async () => {
  const { db, app, auth } = await setup();
  const ins = db.prepare("INSERT INTO sessions (id, project_id, kind, claude_session_id, status, created_at) VALUES (?,?,?,?,?,?)");
  const old = new Date(Date.now() - 10 * 86_400_000).toISOString();
  ins.run("s_old", "p_ok", "claude", "sess-old", "stale", old);
  ins.run("s_new", "p_ok", "claude", "sess-new", "stale", new Date().toISOString());
  ins.run("s_live", "p_ok", "claude", "sess-live", "live", old);
  const prune = (payload: unknown) => app.inject({ method: "POST", url: "/sessions/prune", headers: auth, payload });

  assert.equal((await prune({})).statusCode, 400);
  assert.deepEqual((await prune({ project_id: "p_ok", older_than_days: 7 })).json(), { deleted: 1 });
  assert.deepEqual((await prune({ project_id: "p_ok" })).json(), { deleted: 1 });
  const left = db.prepare("SELECT id FROM sessions").all() as any[];
  assert.deepEqual(left.map((r) => r.id), ["s_live"]);
  const dismissed = db.prepare("SELECT claude_session_id FROM dismissed_transcripts ORDER BY 1").all() as any[];
  assert.deepEqual(dismissed.map((r) => r.claude_session_id), ["sess-new", "sess-old"]);
});

// ADR 0013: a notification action answers without a WS attach. A fake engine
// stands in — the gate itself is covered in claude.test.ts.
test("pending + REST answers: 204 when waiting, 410 once resolved, device attributed", async () => {
  const { db, app, auth, registry } = await setup();
  const { id } = (await post(app, auth, { project_id: "p_ok", kind: "claude" })).json();
  const waiting = new Set(["tu1"]);
  const answered: unknown[][] = [];
  registry.set(id, {
    pending: () => ({ permissions: [{ t: "permission_request", toolUseID: "tu1", toolName: "Bash" }], dialogs: [] }),
    onPermission: (t: string, allow: boolean, dev?: string | null) => (answered.push([t, allow, dev]), waiting.delete(t)),
    onDialogResponse: () => false,
  } as any);

  const pending = (await app.inject({ method: "GET", url: `/sessions/${id}/pending`, headers: auth })).json();
  assert.equal(pending.permissions[0].toolUseID, "tu1");
  assert.deepEqual(pending.dialogs, []);

  const answer = (body: unknown) =>
    app.inject({ method: "POST", url: `/sessions/${id}/permission`, headers: auth, payload: body as any });
  assert.equal((await answer({ toolUseID: "tu1" })).statusCode, 400);
  assert.equal((await answer({ toolUseID: "tu1", allow: true })).statusCode, 204);
  assert.equal((await answer({ toolUseID: "tu1", allow: true })).statusCode, 410);
  const me = (db.prepare("SELECT id FROM devices").get() as { id: string }).id;
  assert.deepEqual(answered[0], ["tu1", true, me]);

  const dialog = await app.inject({
    method: "POST",
    url: `/sessions/${id}/dialog`,
    headers: auth,
    payload: { dialogId: "d1", completed: true, result: {} },
  });
  assert.equal(dialog.statusCode, 410);
  // No running engine → nothing waiting, not an error; unknown session → 404.
  registry.delete(id);
  assert.deepEqual((await app.inject({ method: "GET", url: `/sessions/${id}/pending`, headers: auth })).json().permissions, []);
  assert.equal((await app.inject({ method: "GET", url: "/sessions/nope/pending", headers: auth })).statusCode, 404);
});

test("POST /devices/fcm stores the caller's token and moves it off any other device", async () => {
  const { db, app, auth } = await setup();
  const me = (db.prepare("SELECT id FROM devices").get() as { id: string }).id;
  db.prepare("INSERT INTO devices (id, name, token_hash, paired_at, fcm_token) VALUES (?,?,?,?,?)").run(
    "old",
    "old phone",
    "x",
    new Date().toISOString(),
    "tok-1",
  );
  const reg = (payload: unknown) => app.inject({ method: "POST", url: "/devices/fcm", headers: auth, payload: payload as any });
  assert.equal((await reg({})).statusCode, 400);
  assert.equal((await reg({ token: "tok-1" })).statusCode, 204);
  const rows = db.prepare("SELECT id, fcm_token FROM devices ORDER BY id").all() as { id: string; fcm_token: string | null }[];
  assert.equal(rows.find((r) => r.id === me)!.fcm_token, "tok-1");
  assert.equal(rows.find((r) => r.id === "old")!.fcm_token, null);
  // Unauthenticated callers never reach it.
  assert.equal((await app.inject({ method: "POST", url: "/devices/fcm", payload: { token: "t" } })).statusCode, 401);
});

test("POST /sessions caps live sessions per kind (429 past the limit; DELETE frees a slot)", async () => {
  const prev = process.env.VIBE_MAX_CLAUDE;
  process.env.VIBE_MAX_CLAUDE = "1";
  try {
    const { app, auth } = await setup();
    const first = await post(app, auth, { project_id: "p_ok", kind: "claude" });
    assert.equal(first.statusCode, 201);
    assert.equal((await post(app, auth, { project_id: "p_ok", kind: "claude" })).statusCode, 429);

    // Freeing the one live slot lets the next create through.
    await app.inject({ method: "DELETE", url: `/sessions/${first.json().id}`, headers: auth });
    assert.equal((await post(app, auth, { project_id: "p_ok", kind: "claude" })).statusCode, 201);
  } finally {
    if (prev === undefined) delete process.env.VIBE_MAX_CLAUDE;
    else process.env.VIBE_MAX_CLAUDE = prev;
  }
});

test("sessions routes reject unauthenticated", async () => {
  const { app } = await setup();
  assert.equal((await app.inject({ method: "GET", url: "/sessions" })).statusCode, 401);
});

test("a live session whose tmux vanished reconciles to stale on GET", async () => {
  const { app, auth, tmux } = await setup();
  const { id } = (await post(app, auth, { project_id: "p_ok", kind: "terminal" })).json();
  tmux.live.delete(id); // simulate reboot: tmux session gone, DB row still 'live'
  const one = await app.inject({ method: "GET", url: `/sessions/${id}`, headers: auth });
  assert.equal(one.json().status, "stale", "GET reconciles a vanished session to stale");
});

// discover.ts — GET /sessions picks up a `claude` CLI transcript for the project.
test("GET /sessions discovers an externally-started session for the project", async () => {
  const claudeRoot = mkdtempSync(join(tmpdir(), "vibe-claude-"));
  const prev = process.env.VIBE_CLAUDE_PROJECTS_DIR;
  process.env.VIBE_CLAUDE_PROJECTS_DIR = claudeRoot;
  try {
    const transcriptDir = join(claudeRoot, encodeProjectPath(REPO_DIR));
    mkdirSync(transcriptDir, { recursive: true });
    writeFileSync(join(transcriptDir, "cli-sess.jsonl"), JSON.stringify({ type: "user", message: { content: "hi" } }) + "\n");

    const { app, auth } = await setup();
    const list = (await app.inject({ method: "GET", url: "/sessions?project_id=p_ok", headers: auth })).json();
    assert.equal(list.length, 1);
    assert.equal(list[0].claude_session_id, "cli-sess");
    assert.equal(list[0].status, "stale");

    // Re-fetch: no duplicate row for the same transcript.
    const again = (await app.inject({ method: "GET", url: "/sessions?project_id=p_ok", headers: auth })).json();
    assert.equal(again.length, 1);
  } finally {
    rmSync(claudeRoot, { recursive: true, force: true });
    if (prev === undefined) delete process.env.VIBE_CLAUDE_PROJECTS_DIR;
    else process.env.VIBE_CLAUDE_PROJECTS_DIR = prev;
  }
});

test("discovered (stale) sessions don't count against the live cap", async () => {
  const claudeRoot = mkdtempSync(join(tmpdir(), "vibe-claude-"));
  const prevDir = process.env.VIBE_CLAUDE_PROJECTS_DIR;
  const prevCap = process.env.VIBE_MAX_CLAUDE;
  process.env.VIBE_CLAUDE_PROJECTS_DIR = claudeRoot;
  process.env.VIBE_MAX_CLAUDE = "1";
  try {
    const transcriptDir = join(claudeRoot, encodeProjectPath(REPO_DIR));
    mkdirSync(transcriptDir, { recursive: true });
    writeFileSync(join(transcriptDir, "cli-sess.jsonl"), JSON.stringify({ type: "user", message: { content: "hi" } }) + "\n");

    const { app, auth } = await setup();
    await app.inject({ method: "GET", url: "/sessions?project_id=p_ok", headers: auth }); // triggers discovery
    assert.equal((await post(app, auth, { project_id: "p_ok", kind: "claude" })).statusCode, 201);
  } finally {
    rmSync(claudeRoot, { recursive: true, force: true });
    if (prevDir === undefined) delete process.env.VIBE_CLAUDE_PROJECTS_DIR;
    else process.env.VIBE_CLAUDE_PROJECTS_DIR = prevDir;
    if (prevCap === undefined) delete process.env.VIBE_MAX_CLAUDE;
    else process.env.VIBE_MAX_CLAUDE = prevCap;
  }
});


// Agent presets (ADR 0016). Detection is pre-warmed with a fake so the route's
// cached lookup never shells out; the client can only name a preset id.
test("presets: GET lists installed ones; POST starts the fixed command, rejects the rest", async () => {
  clearPresetCache();
  await installedPresets(async () => ["codex"]);
  try {
    const { app, auth, tmux } = await setup();
    const list = await app.inject({ method: "GET", url: "/presets", headers: auth });
    assert.deepEqual(list.json(), { presets: [{ id: "codex", label: "Codex CLI" }] });

    const ok = await post(app, auth, { project_id: "p_ok", kind: "terminal", preset: "codex" });
    assert.equal(ok.statusCode, 201);
    assert.equal(ok.json().title, "Codex CLI");
    assert.equal(tmux.commands.get(ok.json().id), "codex");

    const plain = await post(app, auth, { project_id: "p_ok", kind: "terminal" });
    assert.equal(tmux.commands.get(plain.json().id), undefined);

    assert.equal((await post(app, auth, { project_id: "p_ok", kind: "terminal", preset: "rm -rf /" })).statusCode, 400);
    assert.equal((await post(app, auth, { project_id: "p_ok", kind: "terminal", preset: ["codex"] })).statusCode, 400);
    assert.equal((await post(app, auth, { project_id: "p_ok", kind: "claude", preset: "codex" })).statusCode, 400);
    const missing = await post(app, auth, { project_id: "p_ok", kind: "terminal", preset: "aider" });
    assert.equal(missing.statusCode, 400);
    assert.match(missing.json().error, /not installed/);
  } finally {
    clearPresetCache();
  }
});
