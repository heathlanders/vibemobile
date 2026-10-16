// ClaudeSession verification with a FAKE Agent SDK (injected queryFn) — no real
// `claude` subprocess, no spend. Covers: init writes claude_session_id, deltas
// stream out, canUseTool round-trips (allow/deny/timeout), and the transcript
// persists + replays as `history` on attach.

import test from "node:test";
import assert from "node:assert/strict";
import { openDb } from "./db.js";
import { ClaudeSession, startIdleReaper, type ClaudeRegistry } from "./claude.js";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
async function waitFor(fn: () => boolean, ms = 1500) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) {
    if (fn()) return;
    await sleep(5);
  }
  throw new Error("timed out waiting for condition");
}

// Records everything the session sends.
function fakeWs() {
  const frames: any[] = [];
  return {
    OPEN: 1,
    readyState: 1,
    frames,
    send: (s: string) => frames.push(JSON.parse(s)),
    on() {},
    ping() {},
    terminate() {},
    closed: [] as Array<[number, string]>,
    close(code: number, reason: string) {
      this.closed.push([code, reason]);
    },
  } as any;
}

function seedDb() {
  const db = openDb(":memory:");
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES (?,?,?,?)").run("p1", "/tmp", "p", "unknown");
  db.prepare("INSERT INTO sessions (id, project_id, kind, status, created_at) VALUES (?,?,?,?,?)").run(
    "s1",
    "p1",
    "claude",
    "live",
    new Date().toISOString(),
  );
  return db;
}

// The full PermissionResult the fake SDK got back from the last canUseTool call —
// lets a test assert the *shape* of the result (not just behavior), e.g. that an
// allow echoes `updatedInput` (the SDK's runtime schema requires it).
let lastDecision: any = null;

// A fake SDK turn: init → 2 text deltas → ask to use Read → assistant text +
// tool_use → result. The permission decision steers the assistant text.
function fakeQuery(params: { prompt: AsyncIterable<any>; options: any }) {
  const { prompt, options } = params;
  return (async function* () {
    yield { type: "system", subtype: "init", session_id: "claude-abc", model: "claude-x" };
    const it = prompt[Symbol.asyncIterator]();
    await it.next(); // wait for the first user turn
    yield { type: "stream_event", event: { type: "content_block_delta", delta: { type: "text_delta", text: "Hel" } } };
    yield { type: "stream_event", event: { type: "content_block_delta", delta: { type: "text_delta", text: "lo" } } };
    const decision: any = await options.canUseTool("Read", { file: "README" }, { toolUseID: "tu1", title: "Read README" });
    lastDecision = decision;
    const verb = decision.behavior === "allow" ? "reading" : "skipping";
    yield {
      type: "assistant",
      message: { content: [{ type: "text", text: verb }, { type: "tool_use", id: "tu1", name: "Read", input: { file: "README" } }] },
    };
    // The SDK feeds the tool's output back as a user turn (proposal 07).
    yield { type: "user", message: { content: [{ type: "tool_result", tool_use_id: "tu1", content: "file body", is_error: false }] } };
    yield { type: "result", subtype: "success", total_cost_usd: 0.01 };
  })();
}

test("init captures claude_session_id; deltas + result stream out", async () => {
  const db = seedDb();
  const ws = fakeWs();
  const s = new ClaudeSession(db, "s1", "/tmp", fakeQuery);
  s.setAutoAllow(false); // exercise the interactive gate (auto-allow is the default)
  s.attach(ws);
  s.start();
  s.pushUser("hi");

  await waitFor(() => ws.frames.some((f: any) => f.t === "permission_request"));
  s.onPermission("tu1", true);
  await waitFor(() => ws.frames.some((f: any) => f.t === "result"));

  const types = ws.frames.map((f: any) => f.t);
  assert.ok(types.includes("init"));
  assert.deepEqual(ws.frames.filter((f: any) => f.t === "delta").map((f: any) => f.text), ["Hel", "lo"]);
  assert.ok(types.includes("tool_use"));
  assert.equal(ws.frames.find((f: any) => f.t === "assistant").text, "reading");
  // claude_session_id persisted for resume
  const row = db.prepare("SELECT claude_session_id FROM sessions WHERE id = 's1'").get() as any;
  assert.equal(row.claude_session_id, "claude-abc");
});

test("allow result echoes updatedInput (SDK runtime schema requires it)", async () => {
  // Regression: a bare {behavior:"allow"} throws a ZodError in the real SDK
  // (updatedInput undefined) and every tool approval errors out. The allow must
  // carry updatedInput = the original tool input.
  const db = seedDb();
  const ws = fakeWs();
  lastDecision = null;
  const s = new ClaudeSession(db, "s1", "/tmp", fakeQuery);
  s.setAutoAllow(false); // exercise the interactive gate (auto-allow is the default)
  s.attach(ws);
  s.start();
  s.pushUser("hi");
  await waitFor(() => ws.frames.some((f: any) => f.t === "permission_request"));
  s.onPermission("tu1", true);
  await waitFor(() => lastDecision !== null);
  assert.equal(lastDecision.behavior, "allow");
  assert.deepEqual(lastDecision.updatedInput, { file: "README" });
});

test("denied permission reaches the model", async () => {
  const db = seedDb();
  const ws = fakeWs();
  const s = new ClaudeSession(db, "s1", "/tmp", fakeQuery);
  s.setAutoAllow(false); // exercise the interactive gate (auto-allow is the default)
  s.attach(ws);
  s.start();
  s.pushUser("hi");
  await waitFor(() => ws.frames.some((f: any) => f.t === "permission_request"));
  s.onPermission("tu1", false);
  await waitFor(() => ws.frames.some((f: any) => f.t === "assistant"));
  assert.equal(ws.frames.find((f: any) => f.t === "assistant").text, "skipping");
  const ev = db.prepare("SELECT detail FROM events WHERE kind = 'permission.deny'").get() as any;
  assert.match(ev.detail, /Read/);
});

test("permission times out → deny, audited", async () => {
  const db = seedDb();
  const ws = fakeWs();
  const s = new ClaudeSession(db, "s1", "/tmp", fakeQuery, 40); // 40ms timeout
  s.setAutoAllow(false); // exercise the interactive gate (auto-allow is the default)
  s.attach(ws);
  s.start();
  s.pushUser("hi");
  // never call onPermission → canUseTool resolves deny on timeout
  await waitFor(() => ws.frames.some((f: any) => f.t === "assistant"));
  assert.equal(ws.frames.find((f: any) => f.t === "assistant").text, "skipping");
  assert.ok(db.prepare("SELECT 1 FROM events WHERE kind = 'permission.timeout'").get());
});

test("transcript persists and replays as history on a fresh attach", async () => {
  const db = seedDb();
  const ws1 = fakeWs();
  const s = new ClaudeSession(db, "s1", "/tmp", fakeQuery);
  s.setAutoAllow(false); // exercise the interactive gate (auto-allow is the default)
  s.attach(ws1);
  s.start();
  s.pushUser("hi");
  await waitFor(() => ws1.frames.some((f: any) => f.t === "permission_request"));
  s.onPermission("tu1", true);
  await waitFor(() => ws1.frames.some((f: any) => f.t === "result"));

  // A second client attaches → gets the stored transcript.
  const ws2 = fakeWs();
  s.attach(ws2);
  const history = ws2.frames.find((f: any) => f.t === "history");
  assert.ok(history, "history frame sent on attach");
  const roles = history.messages.map((m: any) => m.role);
  assert.ok(roles.includes("user") && roles.includes("assistant") && roles.includes("result"));
});

test("every attached socket gets the turn's frames; detach removes only that socket", async () => {
  const db = seedDb();
  const s = new ClaudeSession(db, "s1", "/tmp", fakeQuery);
  const ws1 = fakeWs();
  const ws2 = fakeWs();
  s.attach(ws1);
  s.attach(ws2);
  s.start();
  s.pushUser("hi");
  await waitFor(() => ws1.frames.some((f: any) => f.t === "result") && ws2.frames.some((f: any) => f.t === "result"));
  s.detach(ws1);
  assert.equal(s.isReapable(0), false, "one socket still attached");
  const n = ws1.frames.length;
  s.announceRewound("m1", []);
  assert.ok(ws2.frames.some((f: any) => f.t === "rewound"));
  assert.equal(ws1.frames.length, n, "the detached socket receives nothing more");
  s.detach(ws2);
  assert.equal(s.isReapable(0), true, "reapable once both detach");
});

test("a user turn: the sender gets user_ack, every other socket gets user_turn", () => {
  const db = seedDb();
  const s = new ClaudeSession(db, "s1", "/tmp", fakeQuery);
  const ws1 = fakeWs();
  const ws2 = fakeWs();
  s.attach(ws1);
  s.attach(ws2);
  s.pushUser("hi from phone", [], ws1);
  const ack = ws1.frames.find((f: any) => f.t === "user_ack");
  const turn = ws2.frames.find((f: any) => f.t === "user_turn");
  assert.ok(ack?.messageId, "sender learns the row id");
  assert.equal(ws1.frames.some((f: any) => f.t === "user_turn"), false, "sender already shows its bubble");
  assert.equal(turn?.text, "hi from phone");
  assert.equal(turn?.messageId, ack.messageId);
  assert.equal(ws2.frames.some((f: any) => f.t === "user_ack"), false);
});

test("permission answered via one socket closes the card on both; a second answer is refused", async () => {
  const db = seedDb();
  const s = new ClaudeSession(db, "s1", "/tmp", fakeQuery);
  const ws1 = fakeWs();
  const ws2 = fakeWs();
  s.setAutoAllow(false);
  s.attach(ws1);
  s.attach(ws2);
  s.start();
  s.pushUser("hi");
  await waitFor(() => ws2.frames.some((f: any) => f.t === "permission_request"));
  assert.equal(s.onPermission("tu1", true), true);
  assert.equal(s.onPermission("tu1", false), false, "first answer wins");
  for (const ws of [ws1, ws2]) assert.ok(ws.frames.some((f: any) => f.t === "permission_closed" && f.toolUseID === "tu1"));
});

test("stop() closes every attached socket with the given code (default 1012)", () => {
  const db = seedDb();
  const s = new ClaudeSession(db, "s1", "/tmp", fakeQuery);
  const ws1 = fakeWs();
  const ws2 = fakeWs();
  s.attach(ws1);
  s.attach(ws2);
  s.stop();
  assert.equal(ws1.closed[0][0], 1012);
  assert.equal(ws2.closed[0][0], 1012);
  const ws3 = fakeWs();
  const s2 = new ClaudeSession(db, "s1", "/tmp", fakeQuery);
  s2.attach(ws3);
  s2.stop(4404);
  assert.equal(ws3.closed[0][0], 4404);
});

test("idle reaper evicts a detached, quiet session but never an attached one", async () => {
  const db = seedDb();
  db.prepare("INSERT INTO sessions (id, project_id, kind, status, created_at) VALUES (?,?,?,?,?)").run(
    "s2",
    "p1",
    "claude",
    "live",
    new Date().toISOString(),
  );
  const registry: ClaudeRegistry = new Map();

  const attached = new ClaudeSession(db, "s1", "/tmp", fakeQuery);
  attached.attach(fakeWs());
  attached.start();

  const detached = new ClaudeSession(db, "s2", "/tmp", fakeQuery);
  detached.start(); // never attached → ws null

  registry.set("s1", attached);
  registry.set("s2", detached);

  const stop = startIdleReaper(registry, db, 0, 5); // idle 0ms, tick every 5ms
  try {
    await waitFor(() => !registry.has("s2"));
    assert.ok(registry.has("s1"), "attached session is never reaped");
    assert.ok(db.prepare("SELECT 1 FROM events WHERE kind = 'session.reap'").get(), "reap audited");
  } finally {
    stop();
  }
});

// The last UserDialogResult the fake SDK got back from onUserDialog — lets a
// test assert the answer shape the client sent reaches the model.
let lastDialog: any = null;

// A fake turn that asks a question via onUserDialog (AskUserQuestion's path —
// NOT canUseTool), then echoes the chosen answer into the assistant text.
function fakeDialogQuery(params: { prompt: AsyncIterable<any>; options: any }) {
  const { prompt, options } = params;
  return (async function* () {
    yield { type: "system", subtype: "init", session_id: "claude-q", model: "claude-x" };
    const it = prompt[Symbol.asyncIterator]();
    await it.next();
    const res: any = await options.onUserDialog({
      dialogKind: "ask_user_question",
      payload: { questions: [{ question: "Pick?", header: "Pick", multiSelect: false, options: [{ label: "A", description: "" }, { label: "B", description: "" }] }] },
      toolUseID: "tu-q",
    });
    lastDialog = res;
    const txt = res.behavior === "completed" ? `chose ${res.result.answers["Pick?"]}` : "cancelled";
    yield { type: "assistant", message: { content: [{ type: "text", text: txt }] } };
    yield { type: "result", subtype: "success", total_cost_usd: 0 };
  })();
}

test("user_dialog round-trips: answer reaches the model as {questions, answers}", async () => {
  const db = seedDb();
  const ws = fakeWs();
  lastDialog = null;
  const s = new ClaudeSession(db, "s1", "/tmp", fakeDialogQuery);
  s.attach(ws);
  s.start();
  s.pushUser("hi");
  await waitFor(() => ws.frames.some((f: any) => f.t === "user_dialog"));
  const dlg = ws.frames.find((f: any) => f.t === "user_dialog");
  assert.equal(dlg.dialogKind, "ask_user_question");
  assert.equal(dlg.toolUseID, "tu-q");
  s.onDialogResponse(dlg.dialogId, true, { questions: dlg.payload.questions, answers: { "Pick?": "B" } });
  await waitFor(() => ws.frames.some((f: any) => f.t === "assistant"));
  assert.equal(ws.frames.find((f: any) => f.t === "assistant").text, "chose B");
  assert.equal(lastDialog.behavior, "completed");
  assert.ok(db.prepare("SELECT 1 FROM events WHERE kind = 'dialog.completed'").get());
});

test("user_dialog cancels on timeout, audited", async () => {
  const db = seedDb();
  const ws = fakeWs();
  const s = new ClaudeSession(db, "s1", "/tmp", fakeDialogQuery, 40); // 40ms timeout
  s.attach(ws);
  s.start();
  s.pushUser("hi");
  await waitFor(() => ws.frames.some((f: any) => f.t === "assistant"));
  assert.equal(ws.frames.find((f: any) => f.t === "assistant").text, "cancelled");
  assert.ok(db.prepare("SELECT 1 FROM events WHERE kind = 'dialog.timeout'").get());
});

test("pending user_dialog is replayed to a reattaching client", async () => {
  const db = seedDb();
  const ws1 = fakeWs();
  const s = new ClaudeSession(db, "s1", "/tmp", fakeDialogQuery);
  s.attach(ws1);
  s.start();
  s.pushUser("hi");
  await waitFor(() => ws1.frames.some((f: any) => f.t === "user_dialog"));
  s.detach(ws1);
  const ws2 = fakeWs();
  s.attach(ws2);
  assert.ok(ws2.frames.some((f: any) => f.t === "user_dialog" && f.toolUseID === "tu-q"));
});

test("pending permission is replayed to a reattaching client", async () => {
  const db = seedDb();
  const ws1 = fakeWs();
  const s = new ClaudeSession(db, "s1", "/tmp", fakeQuery);
  s.setAutoAllow(false); // exercise the interactive gate (auto-allow is the default)
  s.attach(ws1);
  s.start();
  s.pushUser("hi");
  await waitFor(() => ws1.frames.some((f: any) => f.t === "permission_request"));

  // Drop and reattach BEFORE answering — the pending request must re-emit.
  s.detach(ws1);
  const ws2 = fakeWs();
  s.attach(ws2);
  assert.ok(ws2.frames.some((f: any) => f.t === "permission_request" && f.toolUseID === "tu1"));
  s.onPermission("tu1", true);
});

// Proposal 16: an attachment id on a user turn becomes an SDK image content block,
// and the transcript persists the ref (not the bytes) so history can redraw it.
test("pushUser with images builds a multimodal turn + persists the ref", async () => {
  const db = seedDb();
  db.prepare("INSERT INTO attachments (id, session_id, media_type, data, created_at) VALUES (?,?,?,?,?)").run(
    "a_1",
    "s1",
    "image/png",
    Buffer.from([0x89, 0x50, 0x4e, 0x47]),
    new Date().toISOString(),
  );
  // Foreign image must NOT be pulled into s1's turn (the session_id ownership gate).
  db.prepare("INSERT INTO sessions (id, project_id, kind, status, created_at) VALUES (?,?,?,?,?)").run(
    "s2", "p1", "claude", "live", new Date().toISOString(),
  );
  db.prepare("INSERT INTO attachments (id, session_id, media_type, data, created_at) VALUES (?,?,?,?,?)").run(
    "a_other", "s2", "image/png", Buffer.from([0x89, 0x50]), new Date().toISOString(),
  );

  let captured: any = null;
  const capturingQuery = (params: { prompt: AsyncIterable<any>; options: any }) =>
    (async function* () {
      yield { type: "system", subtype: "init", session_id: "c1", model: "m" };
      const it = params.prompt[Symbol.asyncIterator]();
      captured = (await it.next()).value;
    })();

  const s = new ClaudeSession(db, "s1", "/tmp", capturingQuery);
  s.attach(fakeWs());
  s.start();
  s.pushUser("look", ["a_1", "a_other"]);
  await waitFor(() => captured !== null);

  const content = captured.message.content;
  assert.ok(Array.isArray(content), "content is an array of blocks");
  assert.deepEqual(content[0], { type: "text", text: "look" });
  assert.equal(content[1].type, "image");
  assert.equal(content[1].source.media_type, "image/png");
  assert.equal(content[1].source.data, Buffer.from([0x89, 0x50, 0x4e, 0x47]).toString("base64"));
  assert.equal(content.length, 2, "the foreign-session image is filtered out");

  // The persisted user row carries the ref (id + mediaType), never the bytes.
  const row = db.prepare("SELECT content, tool_json FROM messages WHERE session_id = 's1' AND role = 'user'").get() as any;
  assert.equal(row.content, "look");
  assert.deepEqual(JSON.parse(row.tool_json), { images: [{ id: "a_1", mediaType: "image/png" }] });
});

test("result accumulates cost in the DB but no longer surfaces it (Max meters replace $)", async () => {
  const db = seedDb();
  const ws = fakeWs();
  const s = new ClaudeSession(db, "s1", "/tmp", fakeQuery);
  s.setAutoAllow(false); // exercise the interactive gate (auto-allow is the default)
  s.attach(ws);
  s.start();
  s.pushUser("hi");
  await waitFor(() => ws.frames.some((f: any) => f.t === "permission_request"));
  s.onPermission("tu1", true);
  await waitFor(() => ws.frames.some((f: any) => f.t === "result"));

  // On a Max subscription the API-equivalent cost is fiction — the result frame
  // no longer carries cost/sessionCost (real usage rides a separate `usage` frame).
  const result = ws.frames.find((f: any) => f.t === "result");
  assert.equal(result.cost, undefined, "no turn cost surfaced");
  assert.equal(result.sessionCost, undefined, "no session total surfaced");
  // But the DB still accumulates it for audit/telemetry.
  const row = db.prepare("SELECT total_cost_usd FROM sessions WHERE id = 's1'").get() as any;
  assert.equal(row.total_cost_usd, 0.01);
});

test("tool_result is emitted and folded onto the tool row (proposal 07)", async () => {
  const db = seedDb();
  const ws = fakeWs();
  const s = new ClaudeSession(db, "s1", "/tmp", fakeQuery);
  s.setAutoAllow(false); // exercise the interactive gate (auto-allow is the default)
  s.attach(ws);
  s.start();
  s.pushUser("hi");
  await waitFor(() => ws.frames.some((f: any) => f.t === "permission_request"));
  s.onPermission("tu1", true);
  await waitFor(() => ws.frames.some((f: any) => f.t === "tool_result"));

  const tr = ws.frames.find((f: any) => f.t === "tool_result");
  assert.equal(tr.toolUseID, "tu1");
  assert.equal(tr.content, "file body");
  assert.equal(tr.isError, false);
  // Folded onto the tool_use row so a reattach replays it under the call.
  const row = db.prepare("SELECT tool_json FROM messages WHERE session_id = 's1' AND role = 'tool'").get() as any;
  const j = JSON.parse(row.tool_json);
  assert.equal(j.id, "tu1");
  assert.equal(j.result, "file body");
  assert.equal(j.isError, false);
});

// Proposal 33: image blocks in a tool_result become attachments; the frame and the
// stored tool row carry their ids. Non-image bytes are dropped and audited.
test("tool_result image blocks are stored as attachments (proposal 33)", async () => {
  const db = seedDb();
  const ws = fakeWs();
  const png = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0]).toString("base64");
  const fake = (params: { prompt: AsyncIterable<any>; options: any }) =>
    (async function* () {
      yield { type: "system", subtype: "init", session_id: "claude-img", model: "claude-x" };
      await params.prompt[Symbol.asyncIterator]().next();
      yield { type: "assistant", message: { content: [{ type: "tool_use", id: "tu9", name: "Read", input: { file_path: "a.png" } }] } };
      yield {
        type: "user",
        message: {
          content: [
            {
              type: "tool_result",
              tool_use_id: "tu9",
              content: [
                { type: "text", text: "img" },
                { type: "image", source: { type: "base64", media_type: "image/png", data: png } },
                { type: "image", source: { type: "base64", media_type: "image/png", data: Buffer.from("nope").toString("base64") } },
              ],
            },
          ],
        },
      };
      yield { type: "result", subtype: "success", total_cost_usd: 0 };
    })();
  const s = new ClaudeSession(db, "s1", "/tmp", fake as any);
  s.attach(ws);
  s.start();
  s.pushUser("hi");
  await waitFor(() => ws.frames.some((f: any) => f.t === "tool_result"));

  const tr = ws.frames.find((f: any) => f.t === "tool_result");
  assert.equal(tr.content, "img");
  assert.equal(tr.images.length, 1, "garbage image dropped");
  const att = db.prepare("SELECT session_id, media_type FROM attachments WHERE id = ?").get(tr.images[0]) as any;
  assert.deepEqual({ ...att }, { session_id: "s1", media_type: "image/png" });
  const row = db.prepare("SELECT tool_json FROM messages WHERE session_id = 's1' AND role = 'tool'").get() as any;
  assert.deepEqual(JSON.parse(row.tool_json).images, tr.images);
  const audit = db.prepare("SELECT detail FROM events WHERE kind = 'attachment.reject'").get() as any;
  assert.match(audit.detail, /^s1:tool_unsupported_type:/);
});

// Auto-allow is the default (claude-ws.md): tool permissions resolve immediately
// with no permission_request round-trip, audited as permission.auto_allow.
test("auto-allow (default) approves without a permission_request, audited", async () => {
  const db = seedDb();
  const ws = fakeWs();
  lastDecision = null;
  const s = new ClaudeSession(db, "s1", "/tmp", fakeQuery);
  s.attach(ws);
  s.start();
  s.pushUser("hi");
  await waitFor(() => ws.frames.some((f: any) => f.t === "result"));
  assert.ok(!ws.frames.some((f: any) => f.t === "permission_request"), "no approval round-trip");
  assert.equal(ws.frames.find((f: any) => f.t === "assistant").text, "reading");
  assert.deepEqual(lastDecision.updatedInput, { file: "README" }); // SDK schema: allow echoes updatedInput
  const ev = db.prepare("SELECT detail FROM events WHERE kind = 'permission.auto_allow'").get() as any;
  assert.match(ev.detail, /Read/);
});

test("turning auto_allow on flushes a pending permission request", async () => {
  const db = seedDb();
  const ws = fakeWs();
  const s = new ClaudeSession(db, "s1", "/tmp", fakeQuery);
  s.setAutoAllow(false);
  s.attach(ws);
  s.start();
  s.pushUser("hi");
  await waitFor(() => ws.frames.some((f: any) => f.t === "permission_request"));
  s.setAutoAllow(true); // mid-approval toggle → the stalled request unblocks
  await waitFor(() => ws.frames.some((f: any) => f.t === "assistant"));
  assert.equal(ws.frames.find((f: any) => f.t === "assistant").text, "reading");
  assert.ok(db.prepare("SELECT 1 FROM events WHERE kind = 'permission.auto_allow'").get());
});

// AskUserQuestion arrives through canUseTool (claude-ws.md). It must NOT be
// auto-allowed past the user, and it never times out — the question waits until
// the client answers.
function fakeAskQuery(params: { prompt: AsyncIterable<any>; options: any }) {
  const { prompt, options } = params;
  return (async function* () {
    yield { type: "system", subtype: "init", session_id: "claude-ask", model: "claude-x" };
    await prompt[Symbol.asyncIterator]().next();
    const decision: any = await options.canUseTool(
      "AskUserQuestion",
      { questions: [{ question: "Pick?", header: "Pick", multiSelect: false, options: [{ label: "A", description: "" }, { label: "B", description: "" }] }] },
      { toolUseID: "tu-ask" },
    );
    const ans = (decision.updatedInput as any)?.answers?.["Pick?"] ?? "unanswered";
    yield { type: "assistant", message: { content: [{ type: "text", text: `answered ${ans}` }] } };
    yield { type: "result", subtype: "success", total_cost_usd: 0 };
  })();
}

test("AskUserQuestion ignores auto-allow and never times out", async () => {
  const db = seedDb();
  const ws = fakeWs();
  const s = new ClaudeSession(db, "s1", "/tmp", fakeAskQuery, 40); // 40ms would have cancelled it before
  s.attach(ws);
  s.start();
  s.pushUser("hi");
  await waitFor(() => ws.frames.some((f: any) => f.t === "user_dialog"));
  await sleep(120); // well past the old timeout — the question must still be pending
  assert.ok(!ws.frames.some((f: any) => f.t === "assistant"), "question still waiting on the user");
  const dlg = ws.frames.find((f: any) => f.t === "user_dialog");
  s.onDialogResponse(dlg.dialogId, true, { questions: dlg.payload.questions, answers: { "Pick?": "B" } });
  await waitFor(() => ws.frames.some((f: any) => f.t === "assistant"));
  assert.equal(ws.frames.find((f: any) => f.t === "assistant").text, "answered B");
});

test("interrupt cancels the in-flight turn without ending the session (proposal 09)", async () => {
  const db = seedDb();
  let interrupted = false;
  // A turn that hangs after a delta until interrupt() is called, then finalizes
  // with subtype 'interrupt' — the session loop stays alive.
  function hangingQuery(params: { prompt: AsyncIterable<any>; options: any }) {
    const { prompt } = params;
    const gen = (async function* () {
      yield { type: "system", subtype: "init", session_id: "claude-int", model: "claude-x" };
      await prompt[Symbol.asyncIterator]().next();
      yield { type: "stream_event", event: { type: "content_block_delta", delta: { type: "text_delta", text: "thinking…" } } };
      while (!interrupted) await sleep(5);
      yield { type: "result", subtype: "interrupt", total_cost_usd: 0 };
    })();
    (gen as any).interrupt = async () => {
      interrupted = true;
    };
    return gen as any;
  }
  const ws = fakeWs();
  const s = new ClaudeSession(db, "s1", "/tmp", hangingQuery);
  s.attach(ws);
  s.start();
  s.pushUser("go");
  await waitFor(() => ws.frames.some((f: any) => f.t === "delta"));
  s.interrupt();
  await waitFor(() => ws.frames.some((f: any) => f.t === "result"));

  assert.equal(interrupted, true, "query.interrupt() was invoked");
  assert.equal(ws.frames.find((f: any) => f.t === "result").subtype, "interrupt");
  assert.equal((db.prepare("SELECT kind FROM events WHERE kind = 'turn.interrupted'").get() as any)?.kind, "turn.interrupted");
});

// ADR 0007 — the per-session model reaches the SDK as options.model, and the
// gateway env is applied (or omitted) based on VIBE_GATEWAY_URL.
test("model + gateway env: options.model set; env applied only when a gateway is configured", async () => {
  const db = seedDb();
  let captured: any = null;
  const capturingQuery = (params: { prompt: AsyncIterable<any>; options: any }) =>
    (async function* () {
      captured = params.options;
      yield { type: "system", subtype: "init", session_id: "c1", model: "m" };
    })();

  const savedUrl = process.env.VIBE_GATEWAY_URL;
  const savedTok = process.env.VIBE_GATEWAY_TOKEN;
  try {
    // With a gateway configured: model passes through + env points at the gateway.
    process.env.VIBE_GATEWAY_URL = "http://127.0.0.1:4000";
    process.env.VIBE_GATEWAY_TOKEN = "tok";
    const routed = new ClaudeSession(db, "s1", "/tmp", capturingQuery, undefined, "gpt-4o");
    routed.start();
    await waitFor(() => captured !== null);
    assert.equal(captured.model, "gpt-4o");
    assert.equal(captured.env.ANTHROPIC_BASE_URL, "http://127.0.0.1:4000");
    assert.equal(captured.env.ANTHROPIC_AUTH_TOKEN, "tok");

    // Default (no gateway, no model): env stays undefined (real Claude via CLI login).
    captured = null;
    delete process.env.VIBE_GATEWAY_URL;
    delete process.env.VIBE_GATEWAY_TOKEN;
    const plain = new ClaudeSession(db, "s1", "/tmp", capturingQuery);
    plain.start();
    await waitFor(() => captured !== null);
    assert.equal(captured.model, undefined);
    assert.equal(captured.env, undefined);
  } finally {
    if (savedUrl === undefined) delete process.env.VIBE_GATEWAY_URL;
    else process.env.VIBE_GATEWAY_URL = savedUrl;
    if (savedTok === undefined) delete process.env.VIBE_GATEWAY_TOKEN;
    else process.env.VIBE_GATEWAY_TOKEN = savedTok;
  }
});

// A fake that serves BOTH shapes the session drives: the multi-turn chat (async
// iterable prompt) and the auto-titler's one-shot string prompt (ADR 0009).
function titlingQuery(params: { prompt: any; options: any }) {
  if (typeof params.prompt === "string") {
    return (async function* () {
      yield { type: "result", subtype: "success", result: "Explain the parser" };
    })();
  }
  return fakeQuery(params);
}

test("first user turn auto-titles, then the refine upgrades it (ADR 0009)", async () => {
  const db = seedDb();
  const ws = fakeWs();
  const s = new ClaudeSession(db, "s1", "/tmp", titlingQuery);
  s.attach(ws);
  s.start();
  s.pushUser("what does the parser do here");

  // Heuristic lands immediately — before the model has said anything.
  assert.equal((db.prepare("SELECT title FROM sessions WHERE id = 's1'").get() as any).title, "tmp · What does the parser do here");
  assert.deepEqual(ws.frames.filter((f: any) => f.t === "title"), [
    { t: "title", title: "tmp · What does the parser do here", auto: true },
  ]);

  await waitFor(() => (db.prepare("SELECT title FROM sessions WHERE id = 's1'").get() as any).title === "tmp · Explain the parser");
  const row = db.prepare("SELECT title, title_auto FROM sessions WHERE id = 's1'").get() as any;
  assert.equal(row.title_auto, 1);
  await waitFor(() => ws.frames.filter((f: any) => f.t === "title").length === 2);

  // A later turn never re-titles.
  s.pushUser("and the lexer?");
  await sleep(30);
  assert.equal((db.prepare("SELECT title FROM sessions WHERE id = 's1'").get() as any).title, row.title);
});

test("attach re-sends the stored title (create-with-prompt is primed before attach)", async () => {
  const db = seedDb();
  db.prepare("UPDATE sessions SET title = 'tmp · Primed', title_auto = 1 WHERE id = 's1'").run();
  const ws = fakeWs();
  new ClaudeSession(db, "s1", "/tmp", fakeQuery).attach(ws);
  assert.deepEqual(ws.frames.filter((f: any) => f.t === "title"), [{ t: "title", title: "tmp · Primed" }]);
});

// ADR 0013: with no phone attached, a waiting permission / question / finished
// turn pushes; an attached phone sees the WS frame instead and gets no push.
test("detached: permission request pushes, and pending() + onPermission answer it", async () => {
  const db = seedDb();
  const s = new ClaudeSession(db, "s1", "/tmp", fakeQuery);
  const pushes: string[] = [];
  s.notify = (t) => pushes.push(t);
  s.setAutoAllow(false);
  s.start(); // never attached
  s.pushUser("hi");
  await waitFor(() => pushes.includes("permission"));
  const [req] = s.pending().permissions as any[];
  assert.equal(req.toolUseID, "tu1");
  assert.equal(s.onPermission("tu1", true, "dev-1"), true);
  assert.equal(s.onPermission("tu1", true, "dev-1"), false, "second answer finds nothing waiting");
  await waitFor(() => pushes.includes("done"));
  const ev = db.prepare("SELECT device_id FROM events WHERE kind = 'permission.allow'").get() as any;
  assert.equal(ev.device_id, "dev-1");
});

test("attached: no pushes for permission or finished turn", async () => {
  const db = seedDb();
  const ws = fakeWs();
  const s = new ClaudeSession(db, "s1", "/tmp", fakeQuery);
  const pushes: string[] = [];
  s.notify = (t) => pushes.push(t);
  s.setAutoAllow(false);
  s.attach(ws);
  s.start();
  s.pushUser("hi");
  await waitFor(() => ws.frames.some((f: any) => f.t === "permission_request"));
  s.onPermission("tu1", true);
  await waitFor(() => ws.frames.some((f: any) => f.t === "result"));
  assert.deepEqual(pushes, []);
});

test("detached: AskUserQuestion waits (no longer auto-skipped) and pushes", async () => {
  const db = seedDb();
  const s = new ClaudeSession(db, "s1", "/tmp", fakeAskQuery);
  const pushes: string[] = [];
  s.notify = (t) => pushes.push(t);
  s.start();
  s.pushUser("hi");
  await waitFor(() => pushes.includes("question"));
  const [dlg] = s.pending().dialogs as any[];
  assert.equal(dlg.dialogKind, "ask_user_question");
  // A phone attaching later still gets it replayed, and can answer it.
  const ws = fakeWs();
  s.attach(ws);
  assert.ok(ws.frames.some((f: any) => f.t === "user_dialog" && f.dialogId === dlg.dialogId));
  assert.equal(s.onDialogResponse(dlg.dialogId, true, { questions: dlg.payload.questions, answers: { "Pick?": "A" } }, "dev-1"), true);
  await waitFor(() => ws.frames.some((f: any) => f.t === "assistant"));
  assert.equal(ws.frames.find((f: any) => f.t === "assistant").text, "answered A");
  assert.equal((db.prepare("SELECT device_id FROM events WHERE kind = 'dialog.completed'").get() as any).device_id, "dev-1");
});

test("status frames: running through the turn, waiting on approval, reattach mid-turn, idle at the end (proposal 32)", async () => {
  const db = seedDb();
  const ws = fakeWs();
  const s = new ClaudeSession(db, "s1", "/tmp", fakeQuery);
  s.setAutoAllow(false);
  s.attach(ws);
  assert.deepEqual(ws.frames.find((f: any) => f.t === "status"), { t: "status", running: false });
  s.start();
  s.pushUser("hi");
  await waitFor(() => ws.frames.some((f: any) => f.t === "permission_request"));

  // Blocked on the approval card.
  const statuses = () => ws.frames.filter((f: any) => f.t === "status");
  assert.equal(statuses().at(-1).phase, "waiting");
  // A fresh socket attaching mid-turn learns the turn is running.
  const ws2 = fakeWs();
  s.attach(ws2);
  const st = ws2.frames.find((f: any) => f.t === "status");
  assert.equal(st.running, true);
  assert.equal(st.phase, "waiting");
  assert.equal(typeof st.elapsedMs, "number");

  s.onPermission("tu1", true);
  await waitFor(() => ws2.frames.some((f: any) => f.t === "result"));
  const after = ws2.frames.filter((f: any) => f.t === "status");
  assert.equal(after.at(-1).running, false, "turn end clears the status");
  const resultIdx = ws2.frames.findIndex((f: any) => f.t === "result");
  assert.ok(ws2.frames.findLastIndex((f: any) => f.t === "status") > resultIdx, "idle status follows result");
  s.stop();
});
