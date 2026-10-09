// Mirror + reply to a running CLI session (ADR 0012, security.md #16). Real app +
// real `ws` client + a REAL tmux on a throwaway -L socket, with `cat` standing in
// for the `claude` pane process (what's pasted is echoed back, so capture-pane
// shows exactly what reached the pane). The CLI registry / transcript live in
// temp dirs. Skipped if no tmux.

import test from "node:test";
import assert from "node:assert/strict";
import { WebSocket } from "ws";
import type { AddressInfo } from "node:net";
import { execFile, spawn } from "node:child_process";
import { promisify } from "node:util";
import { mkdtempSync, mkdirSync, writeFileSync, appendFileSync, readFileSync, rmSync, statSync, utimesSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { openDb } from "./db.js";
import { buildApp } from "./app.js";
import { createPairingCode } from "./auth.js";
import { encodeProjectPath } from "./discover.js";
import { exportMirrorImages, questionKeys, realVcTmux, runningCliSessions } from "./external.js";
import type { Tmux } from "./tmux.js";

const execFileP = promisify(execFile);
const tmuxInstalled = await execFileP("tmux", ["-V"]).then(() => true, () => false);
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
async function waitFor(fn: () => boolean | Promise<boolean>, ms = 4000) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) {
    if (await fn()) return;
    await sleep(20);
  }
  throw new Error("timed out");
}

const noTmux: Tmux = {
  async ensureGlobals() {},
  async createSession() {},
  async hasSession() {
    return false;
  },
  async detachOthers() {},
  attach() {
    throw new Error("unused");
  },
  async killSession() {},
  async sweepStale() {},
};

const neverQuery = () => {
  throw new Error("the Agent SDK must not start while a CLI owns the session");
};

const tmp = mkdtempSync(join(tmpdir(), "vibe-ext-"));
const projectDir = join(tmp, "proj");
const claudeRoot = join(tmp, "projects");
const sessionsDir = join(tmp, "sessions");
mkdirSync(projectDir);
mkdirSync(sessionsDir);
process.env.VIBE_CLAUDE_PROJECTS_DIR = claudeRoot;
process.env.VIBE_CLAUDE_SESSIONS_DIR = sessionsDir;
process.env.VIBE_PROJECT_ROOTS = tmp;
process.env.VIBE_MIRROR_POLL_MS = "50";
process.env.VIBE_VC_KEY_DELAY_MS = "0";
process.env.VIBE_AUTO_TITLE_LLM = "0";
const SOCK = `vctest-${process.pid}`;
process.env.VIBE_VC_TMUX_SOCKET = SOCK;
test.after(async () => {
  await execFileP("tmux", ["-L", SOCK, "kill-server"]).catch(() => {});
  rmSync(tmp, { recursive: true, force: true });
});

const transcript = join(claudeRoot, encodeProjectPath(projectDir), "cli-1.jsonl");
const line = (o: object) => JSON.stringify(o) + "\n";
const procStart = (pid: number) => {
  const s = readFileSync(`/proc/${pid}/stat`, "utf8");
  return s.slice(s.lastIndexOf(")") + 2).split(" ")[19];
};
function register(pid: number, sessionId = "cli-1", cwd = projectDir) {
  writeFileSync(
    join(sessionsDir, `${pid}.json`),
    JSON.stringify({ pid, sessionId, cwd, procStart: procStart(pid), status: "busy" }),
  );
}

// A `cat` pane on the test socket, named like `vc` would; returns its pid.
async function vcPane(name: string): Promise<number> {
  await execFileP("tmux", ["-L", SOCK, "new-session", "-d", "-s", name, "-x", "80", "-y", "20", "cat"]);
  const { stdout } = await execFileP("tmux", ["-L", SOCK, "list-panes", "-t", `=${name}:`, "-F", "#{pane_pid}"]);
  return Number(stdout.trim());
}
const capture = async (name: string) =>
  (await execFileP("tmux", ["-L", SOCK, "capture-pane", "-p", "-t", `=${name}:`])).stdout;

async function boot() {
  const db = openDb(":memory:");
  const app = await buildApp(db, noTmux, new Map(), neverQuery);
  await app.listen({ host: "127.0.0.1", port: 0 });
  const port = (app.server.address() as AddressInfo).port;
  const { token } = (
    await app.inject({ method: "POST", url: "/pair", payload: { code: createPairingCode(db), device_name: "t" } })
  ).json();
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES (?,?,?,?)").run("p1", projectDir, "proj", "unknown");
  db.prepare(
    "INSERT INTO sessions (id, project_id, kind, claude_session_id, status, created_at) VALUES (?,?,?,?,?,?)",
  ).run("s1", "p1", "claude", "cli-1", "stale", new Date().toISOString());
  return { db, app, port, token };
}

function connect(port: number, path: string, token: string) {
  const frames: any[] = [];
  const ws = new WebSocket(`ws://127.0.0.1:${port}${path}`, { headers: { authorization: `Bearer ${token}` } });
  ws.on("message", (d: Buffer) => {
    try {
      frames.push(JSON.parse(d.toString("utf8")));
    } catch {
      frames.push(d.toString("utf8")); // tty bytes
    }
  });
  const closed = new Promise<number>((res) => ws.on("close", (c) => res(c)));
  const opened = new Promise<void>((res) => ws.on("open", () => res()));
  return { ws, frames, closed, opened };
}

test("runningCliSessions: live pid counts, dead or reused pid doesn't", { skip: !tmuxInstalled }, async () => {
  register(process.pid, "me");
  writeFileSync(join(sessionsDir, "999999.json"), JSON.stringify({ pid: 999999, sessionId: "dead", cwd: "/", procStart: "1" }));
  writeFileSync(
    join(sessionsDir, `${process.ppid}.json`),
    JSON.stringify({ pid: process.ppid, sessionId: "reused", cwd: "/", procStart: "12345678999" }),
  );
  const running = runningCliSessions();
  assert.equal(running.get("me")?.pid, process.pid);
  assert.ok(!running.has("dead"));
  assert.ok(!running.has("reused"), "procStart mismatch = pid reused by another process");
  for (const f of [`${process.pid}.json`, "999999.json", `${process.ppid}.json`]) rmSync(join(sessionsDir, f));
});

test("runningCliSessions skips the daemon's own children (its Agent SDK subprocess)", async () => {
  const child = spawn("sleep", ["30"]);
  try {
    await new Promise((r) => child.once("spawn", r));
    register(child.pid!, "own-sdk");
    assert.ok(!runningCliSessions().has("own-sdk"));
  } finally {
    child.kill();
    rmSync(join(sessionsDir, `${child.pid}.json`), { force: true });
  }
});

test("mirror: history from transcript, live tail, reply pastes into the vc pane, 4410 on exit", { skip: !tmuxInstalled }, async (t) => {
  mkdirSync(join(claudeRoot, encodeProjectPath(projectDir)), { recursive: true });
  writeFileSync(transcript, line({ type: "user", timestamp: "2026-09-27T10:00:00.000Z", message: { content: "from the PC" } }));
  const pid = await vcPane("vc-proj");
  register(pid);
  const { db, app, port, token } = await boot();
  t.after(() => app.close());

  const { ws, frames, closed, opened } = connect(port, "/session/s1", token);
  await opened;
  await waitFor(() => frames.some((f) => f.t === "external"));
  const history = frames.find((f) => f.t === "history");
  assert.deepEqual(history.messages.map((m: any) => m.content), ["from the PC"]);
  assert.deepEqual(frames.find((f) => f.t === "external"), { t: "external", status: "busy", canReply: true });

  // The CLI keeps working: new lines stream as ordinary frames. A trailing
  // partial line (mid-write) must wait for its newline.
  appendFileSync(
    transcript,
    line({ type: "assistant", timestamp: "2026-09-27T10:00:01.000Z", message: { content: [{ type: "text", text: "on it" }, { type: "tool_use", id: "tu1", name: "Read", input: { f: 1 } }] } }),
  );
  const partial = line({ type: "user", timestamp: "2026-09-27T10:00:02.000Z", message: { content: [{ type: "tool_result", tool_use_id: "tu1", content: "file body" }] } });
  appendFileSync(transcript, partial.slice(0, 20));
  await waitFor(() => frames.some((f) => f.t === "tool_use"));
  assert.equal(frames.find((f) => f.t === "assistant").text, "on it");
  await sleep(150);
  assert.ok(!frames.some((f) => f.t === "tool_result"), "partial line not parsed yet");
  appendFileSync(transcript, partial.slice(20));
  await waitFor(() => frames.some((f) => f.t === "tool_result" && f.content === "file body"));
  const tool = db.prepare("SELECT tool_json FROM messages WHERE session_id='s1' AND role='tool'").get() as any;
  assert.equal(JSON.parse(tool.tool_json).result, "file body", "result folded onto the tool row");

  // Reply from the phone lands in the pane as one (multi-line) paste.
  ws.send(JSON.stringify({ t: "user", text: "also check\nthe tests" }));
  await waitFor(async () => (await capture("vc-proj")).includes("the tests"));
  const audited = () => db.prepare("SELECT device_id FROM events WHERE kind = 'external.input'").get() as any;
  await waitFor(() => !!audited());
  assert.ok(audited().device_id, "input audited with the device");

  // An image rides along as its own pasted file path (the CLI makes it [Image #N]).
  process.env.VIBE_MIRROR_IMAGE_DIR = mkdtempSync(join(tmpdir(), "mirror-img-"));
  db.prepare("INSERT INTO attachments (id, session_id, media_type, data, created_at) VALUES (?,?,?,?,?)").run(
    "a_ab12", "s1", "image/png", Buffer.from([0x89, 0x50, 0x4e, 0x47]), new Date().toISOString(),
  );
  ws.send(JSON.stringify({ t: "user", text: "see", images: ["a_ab12"] }));
  await waitFor(async () => (await capture("vc-proj")).includes("a_ab12.png"));
  await waitFor(() => !!db.prepare("SELECT 1 FROM events WHERE kind = 'external.input' AND detail = 's1:images=1'").get());
  delete process.env.VIBE_MIRROR_IMAGE_DIR;

  // The CLI exits → 4410 so the client reconnects onto the normal resume path.
  await execFileP("tmux", ["-L", SOCK, "kill-session", "-t", "=vc-proj"]);
  assert.equal(await closed, 4410);
  rmSync(join(sessionsDir, `${pid}.json`));
});

test("mirror: CLI outside vc is read-only — reply refused, nothing typed", { skip: !tmuxInstalled }, async (t) => {
  mkdirSync(join(claudeRoot, encodeProjectPath(projectDir)), { recursive: true });
  writeFileSync(transcript, line({ type: "user", timestamp: "2026-09-27T10:00:00.000Z", message: { content: "hi" } }));
  // Same pane, but NOT named vc-* → not repliable.
  const pid = await vcPane("mine");
  register(pid);
  const { app, port, token } = await boot();
  t.after(async () => {
    app.close();
    rmSync(join(sessionsDir, `${pid}.json`));
    await execFileP("tmux", ["-L", SOCK, "kill-session", "-t", "=mine"]).catch(() => {});
  });

  const { ws, frames, opened } = connect(port, "/session/s1", token);
  await opened;
  await waitFor(() => frames.some((f) => f.t === "external"));
  assert.equal(frames.find((f) => f.t === "external").canReply, false);
  ws.send(JSON.stringify({ t: "user", text: "should not arrive" }));
  await waitFor(() => frames.some((f) => f.t === "error"));
  assert.ok(!(await capture("mine")).includes("should not arrive"));
  ws.close();
});

// Proposal 33: a tailed tool_result's image blocks become attachments (frame +
// folded tool row); a reattach re-imports the transcript but reuses the blobs.
test("mirror: tool_result images → attachments, live and on reattach", { skip: !tmuxInstalled }, async (t) => {
  mkdirSync(join(claudeRoot, encodeProjectPath(projectDir)), { recursive: true });
  writeFileSync(
    transcript,
    line({ type: "assistant", timestamp: "2026-09-27T10:00:00.000Z", message: { content: [{ type: "tool_use", id: "tu7", name: "Read", input: { file_path: "a.png" } }] } }),
  );
  const pid = await vcPane("img");
  register(pid);
  const { db, app, port, token } = await boot();
  t.after(async () => {
    app.close();
    rmSync(join(sessionsDir, `${pid}.json`));
    await execFileP("tmux", ["-L", SOCK, "kill-session", "-t", "=img"]).catch(() => {});
  });

  const a = connect(port, "/session/s1", token);
  await a.opened;
  await waitFor(() => a.frames.some((f) => f.t === "external"));
  const png = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 7]).toString("base64");
  appendFileSync(
    transcript,
    line({
      type: "user",
      timestamp: "2026-09-27T10:00:01.000Z",
      message: {
        content: [
          {
            type: "tool_result",
            tool_use_id: "tu7",
            content: [
              { type: "image", source: { type: "base64", media_type: "image/png", data: png } },
              { type: "image", source: { type: "base64", media_type: "image/png", data: Buffer.from("nope").toString("base64") } },
            ],
          },
        ],
      },
    }),
  );
  await waitFor(() => a.frames.some((f) => f.t === "tool_result"));
  const tr = a.frames.find((f) => f.t === "tool_result");
  assert.equal(tr.images.length, 1, "junk dropped");
  const att = db.prepare("SELECT session_id, media_type FROM attachments WHERE id = ?").get(tr.images[0]) as any;
  assert.deepEqual({ ...att }, { session_id: "s1", media_type: "image/png" });
  const tool = db.prepare("SELECT tool_json FROM messages WHERE session_id='s1' AND role='tool'").get() as any;
  assert.deepEqual(JSON.parse(tool.tool_json).images, tr.images, "folded onto the tool row");
  assert.match((db.prepare("SELECT detail FROM events WHERE kind = 'attachment.reject'").get() as any).detail, /^s1:tool_unsupported_type:/);
  a.ws.close();
  await a.closed;

  // Reattach: the mirror wipes + re-imports; history replays the same id, no new blob.
  const b = connect(port, "/session/s1", token);
  await b.opened;
  await waitFor(() => b.frames.some((f) => f.t === "history"));
  const row = b.frames.find((f) => f.t === "history").messages.find((m: any) => m.role === "tool");
  assert.deepEqual(JSON.parse(row.tool_json).images, tr.images);
  assert.equal((db.prepare("SELECT COUNT(*) AS n FROM attachments").get() as any).n, 1);
  b.ws.close();
});

test("mirror: a vc pane in ANOTHER directory is not repliable",{ skip: !tmuxInstalled }, async (t) => {
  const pid = await vcPane("vc-other");
  register(pid, "cli-1", tmpdir()); // CLI cwd ≠ the row's project path
  const { app, port, token } = await boot();
  t.after(async () => {
    app.close();
    rmSync(join(sessionsDir, `${pid}.json`));
    await execFileP("tmux", ["-L", SOCK, "kill-session", "-t", "=vc-other"]).catch(() => {});
  });
  const { ws, frames, opened } = connect(port, "/session/s1", token);
  await opened;
  await waitFor(() => frames.some((f) => f.t === "external"));
  assert.equal(frames.find((f) => f.t === "external").canReply, false);
  ws.close();
});

test("tty: attaches to the vc pane (keystrokes reach it); 4404 when not running", { skip: !tmuxInstalled }, async (t) => {
  const pid = await vcPane("vc-tty");
  register(pid);
  const { db, app, port, token } = await boot();
  t.after(async () => {
    app.close();
    await execFileP("tmux", ["-L", SOCK, "kill-session", "-t", "=vc-tty"]).catch(() => {});
  });

  const { ws, opened } = connect(port, "/session/s1/tty", token);
  await opened;
  await sleep(200);
  ws.send("0typed-on-phone\r");
  await waitFor(async () => (await capture("vc-tty")).includes("typed-on-phone"));
  assert.ok(db.prepare("SELECT 1 FROM events WHERE kind = 'external.tty'").get());
  ws.close();
  await sleep(100);
  assert.ok((await realVcTmux(SOCK).panes()).some((p) => p.name === "vc-tty"), "closing the tty detaches, never kills");

  rmSync(join(sessionsDir, `${pid}.json`));
  const gone = connect(port, "/session/s1/tty", token);
  assert.equal(await gone.closed, 4404);
});

const ASK = {
  questions: [
    { question: "Which fruits?", header: "Fruit", multiSelect: true, options: [{ label: "Apple" }, { label: "Banana" }, { label: "Cherry" }] },
    { question: "Which pet?", header: "Pet", multiSelect: false, options: [{ label: "Cat" }, { label: "Dog" }] },
  ],
};

test("questionKeys: digits per question, Tab after multi-select, 1 submits the review screen", () => {
  const one = [ASK.questions[1]];
  assert.deepEqual(questionKeys(one, { "Which pet?": "Dog" }), ["2"], "single question, single-select: digit submits");
  assert.deepEqual(questionKeys(ASK.questions, { "Which fruits?": "Apple, Cherry", "Which pet?": "Dog" }), ["1", "3", "Tab", "2", "1"]);
  assert.deepEqual(questionKeys([ASK.questions[0]], { "Which fruits?": "Banana" }), ["2", "Tab", "1"]);
  assert.equal(questionKeys(one, { "Which pet?": "a lizard" }), null, "free text is never typed");
  assert.equal(questionKeys(one, {}), null, "unanswered question");
  assert.equal(questionKeys(one, { "Which pet?": "Cat, Dog" }), null, "two picks on a single-select");
  assert.equal(questionKeys([], {}), null);
});

test("mirror: AskUserQuestion → user_dialog; the answer is typed as menu keys; dialog_closed on result", { skip: !tmuxInstalled }, async (t) => {
  mkdirSync(join(claudeRoot, encodeProjectPath(projectDir)), { recursive: true });
  // Attached while the CLI already waits on a question → replayed after history.
  writeFileSync(
    transcript,
    line({ type: "assistant", timestamp: "2026-09-27T10:00:00.000Z", message: { content: [{ type: "tool_use", id: "q1", name: "AskUserQuestion", input: ASK }] } }),
  );
  const pid = await vcPane("vc-ask");
  register(pid);
  const { db, app, port, token } = await boot();
  t.after(async () => {
    app.close();
    rmSync(join(sessionsDir, `${pid}.json`), { force: true });
    await execFileP("tmux", ["-L", SOCK, "kill-session", "-t", "=vc-ask"]).catch(() => {});
  });

  const { ws, frames, opened } = connect(port, "/session/s1", token);
  await opened;
  await waitFor(() => frames.some((f) => f.t === "user_dialog"));
  assert.deepEqual(frames.find((f) => f.t === "user_dialog"), {
    t: "user_dialog", dialogId: "q1", dialogKind: "ask_user_question", payload: ASK, toolUseID: "q1",
  });

  // Stale id → nothing typed. Free text → error + the question re-sent.
  ws.send(JSON.stringify({ t: "dialog_response", dialogId: "nope", completed: true, result: { answers: { "Which pet?": "Dog" } } }));
  ws.send(JSON.stringify({ t: "dialog_response", dialogId: "q1", completed: true, result: { answers: { "Which fruits?": "Apple", "Which pet?": "a lizard" } } }));
  await waitFor(() => frames.filter((f) => f.t === "user_dialog").length === 2);
  assert.ok(frames.some((f) => f.t === "error"));
  assert.equal((await capture("vc-ask")).trim(), "", "nothing reached the pane");

  ws.send(JSON.stringify({ t: "dialog_response", dialogId: "q1", completed: true, result: { answers: { "Which fruits?": "Apple, Cherry", "Which pet?": "Dog" } } }));
  await waitFor(async () => /13\s+21/.test(await capture("vc-ask")));
  await waitFor(() => !!db.prepare("SELECT device_id FROM events WHERE kind = 'external.dialog'").get());

  // The CLI records the answer → the card is withdrawn.
  appendFileSync(
    transcript,
    line({ type: "user", timestamp: "2026-09-27T10:00:01.000Z", message: { content: [{ type: "tool_result", tool_use_id: "q1", content: "answered" }] } }),
  );
  await waitFor(() => frames.some((f) => f.t === "dialog_closed" && f.dialogId === "q1"));
  ws.close();
});

test("GET /sessions flags a row whose CLI is running", { skip: !tmuxInstalled }, async (t) => {
  register(process.pid);
  const { app, token } = await boot();
  t.after(() => {
    app.close();
    rmSync(join(sessionsDir, `${process.pid}.json`));
  });
  const list = (
    await app.inject({ method: "GET", url: "/sessions?project_id=p1", headers: { authorization: `Bearer ${token}` } })
  ).json();
  assert.deepEqual(list.find((r: any) => r.id === "s1").external, { status: "busy" });
});

test("exportMirrorImages: owned ids only, private modes, safe names, 24 h sweep", () => {
  const db = openDb(":memory:");
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES ('p','/tmp','p','unknown')").run();
  for (const id of ["s1", "s2"]) db.prepare("INSERT INTO sessions (id, project_id, kind, status, created_at) VALUES (?,?,?,?,?)").run(id, "p", "claude", "live", "x");
  const put = (id: string, sid: string, type: string) =>
    db.prepare("INSERT INTO attachments (id, session_id, media_type, data, created_at) VALUES (?,?,?,?,?)").run(id, sid, type, Buffer.from("img"), "x");
  put("a_01", "s1", "image/png");
  put("a_02", "s1", "image/jpeg");
  put("a_03", "s2", "image/png"); // another session's
  const dir = join(mkdtempSync(join(tmpdir(), "mimg-")), "out");
  mkdirSync(dir, { mode: 0o755 });
  const stale = join(dir, "a_old.png");
  writeFileSync(stale, "x");
  utimesSync(stale, new Date(0), new Date(0));

  const paths = exportMirrorImages(db, "s1", ["a_02", "a_03", "../etc/passwd", "a_nope", "a_01"], dir);
  assert.deepEqual(paths, [join(dir, "a_02.jpg"), join(dir, "a_01.png")], "order kept; foreign/bad/unknown ids dropped");
  assert.equal(statSync(dir).mode & 0o777, 0o700, "dir tightened to 0700");
  assert.equal(statSync(paths[0]).mode & 0o777, 0o600);
  assert.equal(readFileSync(paths[1], "utf8"), "img");
  assert.equal(existsSync(stale), false, "files older than 24 h swept");
  assert.deepEqual(exportMirrorImages(db, "s1", [], dir), []);
});
