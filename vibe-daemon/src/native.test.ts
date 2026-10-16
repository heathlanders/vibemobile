// NativeSession + native tools with a FAKE Vercel AI SDK (injected streamTextFn) —
// no real API call, no spend (the analog of claude.test.ts's fake queryFn). Covers
// Tier-1 chat frames + cost + persistence + multi-turn resume, the gated read-only
// tools (approve-before-exec + pathInRoots scoping), and provider routing.

import test from "node:test";
import assert from "node:assert/strict";
import { openDb } from "./db.js";
import { NativeSession, replayHistory, toolNote } from "./native.js";
import { buildNativeTools } from "./native-tools.js";
import { PermissionGate } from "./permission-gate.js";
import { providerFor, isNativeProvider } from "./gateway.js";

// The auto-titler's LLM refine (ADR 0009) fires at the end of every turn. These
// sessions inject no title queryFn, so leaving it on would spawn a REAL Agent SDK
// subprocess per turn. Off for the file; the titling test re-enables it around
// its own fake.
process.env.VIBE_AUTO_TITLE_LLM = "0";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
// The fake streamText ignores the model, but building it needs a configured provider.
process.env.OPENAI_API_KEY ??= "sk-test";
async function waitFor(fn: () => boolean, ms = 1500) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) {
    if (fn()) return;
    await sleep(5);
  }
  throw new Error("timed out");
}

function fakeWs() {
  const frames: any[] = [];
  return { OPEN: 1, readyState: 1, frames, send: (s: string) => frames.push(JSON.parse(s)), on() {}, ping() {}, terminate() {}, closed: [] as any[], close(code: number) { this.closed.push(code); } } as any;
}

function seedDb() {
  const db = openDb(":memory:");
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES (?,?,?,?)").run("p1", "/tmp", "p", "unknown");
  db.prepare("INSERT INTO sessions (id, project_id, kind, status, created_at, model) VALUES (?,?,?,?,?,?)").run(
    "s1", "p1", "claude", "live", new Date().toISOString(), "gpt-4o",
  );
  return db;
}

// A fake streamText: yields the given fullStream parts and records the messages it
// was called with (for the multi-turn resume assertion).
function fakeStream(parts: any[], calls?: any[][], genAssistant = "reply") {
  return (args: any) => {
    calls?.push(args.messages.map((m: any) => ({ ...m }))); // snapshot (the engine mutates the array)
    return {
      fullStream: (async function* () {
        for (const p of parts) yield p;
      })(),
      response: Promise.resolve({ messages: [{ role: "assistant", content: genAssistant }] }),
    };
  };
}

test("chat: init + deltas + assistant + result stream out, and persist", async () => {
  const db = seedDb();
  const parts = [
    { type: "text-delta", id: "t", text: "Hel" },
    { type: "text-delta", id: "t", text: "lo" },
    { type: "finish", finishReason: "stop", totalUsage: { inputTokens: 10, outputTokens: 5 } },
  ];
  const s = new NativeSession(db, "s1", "/tmp", "openai:gpt-4o", fakeStream(parts));
  const ws = fakeWs();
  s.attach(ws);
  s.pushUser("hi");
  await waitFor(() => ws.frames.some((f: any) => f.t === "result"));

  const t = (k: string) => ws.frames.filter((f: any) => f.t === k);
  assert.equal(t("init")[0].model, "openai:gpt-4o");
  assert.equal(t("init")[0].claudeSessionId, undefined, "native init omits claudeSessionId");
  assert.deepEqual(t("delta").map((f: any) => f.text), ["Hel", "lo"]);
  assert.equal(t("assistant")[0].text, "Hello");
  // gpt-4o: (10*2.5 + 5*10)/1e6 = 0.000075
  assert.ok(Math.abs(t("result")[0].cost - 0.000075) < 1e-9);
  assert.ok(t("result")[0].sessionCost > 0);

  const roles = (db.prepare("SELECT role FROM messages WHERE session_id='s1' ORDER BY ts").all() as any[]).map((r) => r.role);
  assert.deepEqual(roles, ["user", "assistant", "result"]);
});

test("two attached sockets both receive the turn; stop() closes both with 1012", async () => {
  const db = seedDb();
  const parts = [{ type: "finish", finishReason: "stop", totalUsage: { inputTokens: 1, outputTokens: 1 } }];
  const s = new NativeSession(db, "s1", "/tmp", "openai:gpt-4o", fakeStream(parts));
  const ws1 = fakeWs();
  const ws2 = fakeWs();
  s.attach(ws1);
  s.attach(ws2);
  s.pushUser("hi");
  await waitFor(() => ws1.frames.some((f: any) => f.t === "result") && ws2.frames.some((f: any) => f.t === "result"));
  s.detach(ws1);
  assert.equal(s.isReapable(0), false);
  s.stop();
  assert.deepEqual(ws2.closed, [1012]);
  assert.deepEqual(ws1.closed, []);
});

test("multi-turn resume: turn 2 sees the full prior transcript", async () => {
  const db = seedDb();
  const calls: any[][] = [];
  const parts = [{ type: "finish", finishReason: "stop", totalUsage: { inputTokens: 1, outputTokens: 1 } }];
  const s = new NativeSession(db, "s1", "/tmp", "openai:gpt-4o", fakeStream(parts, calls, "ok"));
  s.attach(fakeWs());
  s.pushUser("first");
  await waitFor(() => calls.length === 1);
  s.pushUser("second");
  await waitFor(() => calls.length === 2);

  // Turn 2's messages include turn 1's user, the appended assistant, and turn 2's user.
  const second = calls[1];
  assert.equal(second[0].content, "first");
  assert.ok(second.some((m: any) => m.role === "assistant" && m.content === "ok"));
  assert.equal(second[second.length - 1].content, "second");
});

test("history replay: a reattach resends the persisted transcript", async () => {
  const db = seedDb();
  db.prepare("INSERT INTO messages (id, session_id, role, content, tool_json, ts) VALUES (?,?,?,?,?,?)").run(
    "m1", "s1", "user", "earlier", null, "2026-01-01T00:00:00Z",
  );
  const s = new NativeSession(db, "s1", "/tmp", "openai:gpt-4o", fakeStream([]));
  const ws = fakeWs();
  s.attach(ws);
  const hist = ws.frames.find((f: any) => f.t === "history");
  assert.equal(hist.messages[0].content, "earlier");
});

test("provider routing: gpt model → native engine", () => {
  const saved = process.env.VIBE_GATEWAY_MODELS;
  process.env.VIBE_GATEWAY_MODELS = JSON.stringify([{ id: "gpt-4o", provider: "openai" }]);
  try {
    assert.equal(providerFor("gpt-4o"), "openai");
    assert.equal(isNativeProvider(providerFor("gpt-4o")), true);
    assert.equal(isNativeProvider(providerFor("claude-opus-4-8")), false); // unknown → anthropic
    assert.equal(isNativeProvider(providerFor(null)), false);
  } finally {
    if (saved === undefined) delete process.env.VIBE_GATEWAY_MODELS;
    else process.env.VIBE_GATEWAY_MODELS = saved;
  }
});

// ---- gated tools (the security-critical native path) ----------------------

function gateTools(db: any, sendFrames: any[]) {
  const gate = new PermissionGate(db, "s1", (f) => sendFrames.push(f), 40);
  const tools = buildNativeTools(gate, process.cwd(), (f) => sendFrames.push(f))!;
  return { gate, tools };
}

test("tool auto-allow (default): read_file returns file content", async () => {
  const db = seedDb();
  const { tools } = gateTools(db, []);
  const out = await (tools.read_file as any).execute({ path: "package.json" }, { toolCallId: "c1" });
  assert.match(out, /vibe-daemon/);
});

test("tool gate off: read_file emits permission_request and blocks until allowed", async () => {
  const db = seedDb();
  const frames: any[] = [];
  const { gate, tools } = gateTools(db, frames);
  gate.setAutoAllow(false);
  const p = (tools.read_file as any).execute({ path: "package.json" }, { toolCallId: "c9" });
  await waitFor(() => frames.some((f) => f.t === "permission_request" && f.toolUseID === "c9"));
  gate.onPermission("c9", true);
  const out = await p;
  assert.match(out, /vibe-daemon/);
  // and a denial short-circuits with no file read
  gate.setAutoAllow(false);
  const p2 = (tools.read_file as any).execute({ path: "package.json" }, { toolCallId: "c10" });
  await waitFor(() => frames.some((f) => f.toolUseID === "c10"));
  gate.onPermission("c10", false);
  assert.equal(await p2, "Denied by user.");
});

test("tool scoping: a path outside project roots is denied even when allowed", async () => {
  const db = seedDb();
  const { tools } = gateTools(db, []); // auto-allow on → gate passes; pathInRoots must still reject
  const out = await (tools.read_file as any).execute({ path: "/etc/passwd" }, { toolCallId: "c2" });
  assert.match(out, /outside the project roots/);
});

test("every audited tool decision is written to events", async () => {
  const db = seedDb();
  const { tools } = gateTools(db, []);
  await (tools.list_dir as any).execute({ path: "." }, { toolCallId: "c3" });
  const n = (db.prepare("SELECT COUNT(*) AS n FROM events WHERE kind = 'permission.auto_allow'").get() as any).n;
  assert.ok(n >= 1);
});

test("native engine auto-titles the first turn and refines it (ADR 0009)", async () => {
  const db = seedDb();
  const parts = [{ type: "finish", finishReason: "stop", totalUsage: { inputTokens: 1, outputTokens: 1 } }];
  const titleQuery = () =>
    (async function* () {
      yield { type: "result", subtype: "success", result: "Explain the parser" };
    })();
  delete process.env.VIBE_AUTO_TITLE_LLM;
  const s = new NativeSession(db, "s1", "/tmp", "openai:gpt-4o", fakeStream(parts), undefined, undefined, titleQuery);
  const ws = fakeWs();
  s.attach(ws);
  s.start();
  s.pushUser("what does the parser do here");

  // Heuristic is written synchronously, before the model replies.
  assert.equal((db.prepare("SELECT title FROM sessions WHERE id = 's1'").get() as any).title, "tmp · What does the parser do here");
  // The refine fires from reportCost, i.e. once the turn resolves.
  await waitFor(() => (db.prepare("SELECT title FROM sessions WHERE id = 's1'").get() as any).title === "tmp · Explain the parser");
  assert.equal(ws.frames.filter((f: any) => f.t === "title").length, 2);
  process.env.VIBE_AUTO_TITLE_LLM = "0";
});

test("unconfigured provider: the turn ends with an error frame instead of rejecting (ADR 0016)", async () => {
  const saved = process.env.XAI_API_KEY;
  delete process.env.XAI_API_KEY;
  try {
    const db = seedDb();
    const s = new NativeSession(db, "s1", "/tmp", "xai:grok-4", fakeStream([]));
    const ws = fakeWs();
    s.attach(ws);
    s.pushUser("hi");
    await waitFor(() => ws.frames.some((f: any) => f.t === "result"));
    const err = ws.frames.find((f: any) => f.t === "error");
    assert.match(err.message, /xAI is not configured/);
    assert.equal(ws.frames.find((f: any) => f.t === "result").subtype, "error");
  } finally {
    if (saved !== undefined) process.env.XAI_API_KEY = saved;
  }
});

test("resume replays tool calls as one-line notes inside the assistant turn (ADR 0008)", () => {
  const tool = (name: string, input: unknown, result?: string, isError = false) =>
    JSON.stringify({ id: "t", name, input, ...(result !== undefined ? { result } : {}), ...(isError ? { isError } : {}) });
  const msgs = replayHistory([
    { role: "user", content: "fix the bug", tool_json: null },
    { role: "tool", content: null, tool_json: tool("read_file", { path: "a.ts" }, "line1\n  line2") },
    { role: "tool", content: null, tool_json: tool("bash", { cmd: "npm test" }, "boom", true) },
    { role: "assistant", content: "Found it.", tool_json: null },
    { role: "user", content: "thanks", tool_json: null },
    { role: "tool", content: null, tool_json: tool("list_files", {}) }, // turn cut off before any text
    { role: "user", content: "still there?", tool_json: null },
    { role: "result", content: null, tool_json: "{}" },
  ]);
  assert.deepEqual(msgs.map((m) => m.role), ["user", "assistant", "user", "assistant", "user"], "strict alternation");
  assert.equal(
    msgs[1].content,
    '[tool read_file {"path":"a.ts"} → line1 line2]\n[tool bash {"cmd":"npm test"} → error: boom]\nFound it.',
  );
  assert.equal(msgs[3].content, "[tool list_files {} → (no result)]");
  assert.equal(toolNote("not json"), null);
  assert.ok(toolNote(tool("read_file", { path: "x" }, "y".repeat(1000)))!.length < 400, "results are clipped");
});

test("a restarted native session sends the tool notes to the model", async () => {
  const db = seedDb();
  const row = (id: string, role: string, content: string | null, toolJson: string | null, ts: string) =>
    db.prepare("INSERT INTO messages (id, session_id, role, content, tool_json, ts) VALUES (?,?,?,?,?,?)").run(id, "s1", role, content, toolJson, ts);
  row("m1", "user", "read a.ts", null, "2026-01-01T00:00:00Z");
  row("m2", "tool", null, JSON.stringify({ id: "t1", name: "read_file", input: { path: "a.ts" }, result: "export const x = 1" }), "2026-01-01T00:00:01Z");
  row("m3", "assistant", "It exports x.", null, "2026-01-01T00:00:02Z");
  const calls: any[][] = [];
  const parts = [{ type: "finish", finishReason: "stop", totalUsage: { inputTokens: 1, outputTokens: 1 } }];
  const s = new NativeSession(db, "s1", "/tmp", "openai:gpt-4o", fakeStream(parts, calls));
  s.attach(fakeWs());
  s.pushUser("what was in it?");
  await waitFor(() => calls.length === 1);
  assert.match(calls[0][1].content, /\[tool read_file \{"path":"a.ts"\} → export const x = 1\]\nIt exports x\./);
});
