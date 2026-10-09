// Slash commands / skills for the composer (proposal 41).

import test from "node:test";
import assert from "node:assert/strict";
import { openDb } from "./db.js";
import { ClaudeSession } from "./claude.js";
import { publicCommands, skillNamesFrom } from "./commands.js";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
async function waitFor(fn: () => boolean, ms = 2000) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) {
    if (fn()) return;
    await sleep(5);
  }
  throw new Error("timed out");
}
const fakeWs = () => {
  const frames: any[] = [];
  return { OPEN: 1, readyState: 1, frames, send: (s: string) => frames.push(JSON.parse(s)), on() {}, ping() {}, terminate() {}, close() {} } as any;
};

const RAW = [
  { name: "compact", description: "Free up context", argumentHint: "<x>", builtin: true },
  { name: "config", description: "Set a setting by key", argumentHint: "key=value", builtin: true },
  { name: "simplify", description: "Review the changed code", argumentHint: "[<target>]" },
  { name: "stripe:test-cards", description: "(stripe) Display Stripe test card numbers", argumentHint: "scenario" },
  { name: "deploy", description: "  Deploy\n  the app  ", argumentHint: "" },
  { name: "code-review", description: "Review a PR", argumentHint: "[<pr#>]", builtin: true }, // a Claude Code *skill*
];
// What getContextUsage() reports as skills (M13 spike): code-review is one, compact/config are not.
const CTX = { skills: { skillFrontmatter: [{ name: "code-review" }, { name: "simplify" }, { name: "deploy" }] } };

test("publicCommands: non-built-ins + built-in SKILLS are offered; terminal built-ins are not; sorted", () => {
  assert.deepEqual(publicCommands(RAW, skillNamesFrom(CTX)).map((c) => c.name), ["code-review", "deploy", "simplify", "stripe:test-cards"]);
});

test("without the skills list only non-built-ins are offered (safe fallback)", () => {
  assert.deepEqual(publicCommands(RAW).map((c) => c.name), ["deploy", "simplify", "stripe:test-cards"]);
});

test("skillNamesFrom reads skillFrontmatter names and shrugs off junk", () => {
  assert.deepEqual([...skillNamesFrom(CTX)].sort(), ["code-review", "deploy", "simplify"]);
  for (const junk of [null, undefined, 5, {}, { skills: null }, { skills: { skillFrontmatter: "x" } }, { skills: { skillFrontmatter: [null, 3, { name: 5 }] } }]) {
    assert.equal(skillNamesFrom(junk).size, 0, JSON.stringify(junk));
  }
});

test("publicCommands tidies text and clips it", () => {
  const c = publicCommands(RAW).find((x) => x.name === "deploy")!;
  assert.equal(c.description, "Deploy the app", "whitespace/newlines collapsed");
  const long = publicCommands([{ name: "x", description: "d".repeat(500), argumentHint: "h".repeat(500) }])[0];
  assert.deepEqual([long.description.length, long.hint.length], [160, 80]);
});

test("a project command sharing a WITHHELD built-in's name is dropped — '/name' would run the built-in", () => {
  const out = publicCommands([
    { name: "config", description: "builtin config", builtin: true },
    { name: "config", description: "a project command also called config" },
    { name: "other", description: "fine" },
  ]);
  assert.deepEqual(out.map((c) => c.name), ["other"]);
});

test("a built-in that IS a skill is offered once, even if a plugin row repeats the name", () => {
  const out = publicCommands([
    { name: "simplify", description: "bundled", builtin: true },
    { name: "simplify", description: "plugin copy" },
  ], new Set(["simplify"]));
  assert.deepEqual(out.map((c) => c.name), ["simplify"]);
});

test("publicCommands rejects bad names, dedupes, caps, and never throws on junk", () => {
  const bad = ["", "-x", "has space", "a/b", "x".repeat(101), "a;rm", "$(id)", "../x"];
  assert.deepEqual(publicCommands(bad.map((name) => ({ name, description: "x" }))), []);
  assert.equal(publicCommands([{ name: "dup" }, { name: "dup" }]).length, 1);
  assert.equal(publicCommands(Array.from({ length: 500 }, (_, i) => ({ name: `c${i}` }))).length, 200);
  for (const junk of [null, undefined, 5, "x", {}, [null, 3, "s", [], { name: 7 }, { name: null }]]) {
    assert.deepEqual(publicCommands(junk), [], JSON.stringify(junk));
  }
});

function make(opts: { commands?: () => Promise<unknown> } = {}) {
  let supportedCalls = 0;
  let emit: ((m: any) => void) | null = null;
  const queryFn = (params: { prompt: AsyncIterable<any>; options: any }) => {
    if (!params.options?.canUseTool) return (async function* () {})();
    const pending: any[] = [];
    emit = (m) => pending.push(m);
    const gen: any = (async function* () {
      yield { type: "system", subtype: "init", session_id: "c", model: "m" };
      for await (const _ of params.prompt) {
        while (pending.length) yield pending.shift();
        yield { type: "result", subtype: "success", total_cost_usd: 0 };
      }
    })();
    gen.supportedCommands = async () => {
      supportedCalls++;
      return opts.commands ? opts.commands() : RAW;
    };
    gen.getContextUsage = async () => CTX;
    return gen;
  };
  const db = openDb(":memory:");
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES ('p','/tmp','p','unknown')").run();
  db.prepare("INSERT INTO sessions (id, project_id, kind, status, created_at) VALUES ('s','p','claude','live',?)").run(new Date().toISOString());
  const ws = fakeWs();
  const s = new ClaudeSession(db, "s", "/tmp", queryFn as any);
  s.attach(ws);
  s.start();
  return { s, ws, calls: () => supportedCalls, push: (m: any) => emit?.(m) };
}

test("after init the daemon sends the filtered command list once", async () => {
  const { ws, calls } = make();
  await waitFor(() => ws.frames.some((f: any) => f.t === "commands"));
  const f = ws.frames.find((x: any) => x.t === "commands");
  assert.deepEqual(f.commands.map((c: any) => c.name), ["code-review", "deploy", "simplify", "stripe:test-cards"]);
  assert.deepEqual(f.commands.find((c: any) => c.name === "simplify"), { name: "simplify", description: "Review the changed code", hint: "[<target>]" });
  assert.equal(calls(), 1);
});

test("a later attach gets the cached list immediately, without asking the SDK again", async () => {
  const { s, ws, calls } = make();
  await waitFor(() => ws.frames.some((f: any) => f.t === "commands"));
  const ws2 = fakeWs();
  s.attach(ws2);
  assert.equal(ws2.frames.filter((f: any) => f.t === "commands").length, 1);
  assert.equal(calls(), 1);
});

test("commands_changed from the SDK updates the list; an identical list sends nothing", async () => {
  const { s, ws, push } = make();
  await waitFor(() => ws.frames.some((f: any) => f.t === "commands"));
  push({ type: "system", subtype: "commands_changed", commands: [...RAW, { name: "newskill", description: "added later" }] });
  s.pushUser("go");
  await waitFor(() => ws.frames.filter((f: any) => f.t === "commands").length === 2);
  assert.ok(ws.frames.filter((f: any) => f.t === "commands")[1].commands.some((c: any) => c.name === "newskill"));
  push({ type: "system", subtype: "commands_changed", commands: [...RAW, { name: "newskill", description: "added later" }] });
  s.pushUser("again");
  await waitFor(() => ws.frames.filter((f: any) => f.t === "result").length === 2);
  assert.equal(ws.frames.filter((f: any) => f.t === "commands").length, 2, "no duplicate frame for an unchanged list");
});

test("if the SDK can't list commands, nothing is sent and the session is fine", async () => {
  const { s, ws } = make({ commands: async () => { throw new Error("nope"); } });
  s.pushUser("hi");
  await waitFor(() => ws.frames.some((f: any) => f.t === "result"));
  assert.equal(ws.frames.some((f: any) => f.t === "commands" || f.t === "error"), false);
});

test("the list arrives at startup, BEFORE any user message (the real SDK only emits init on the first message)", async () => {
  const queryFn = (params: { prompt: AsyncIterable<any>; options: any }) => {
    if (!params.options?.canUseTool) return (async function* () {})();
    const gen: any = (async function* () {
      for await (const _ of params.prompt) {
        yield { type: "system", subtype: "init", session_id: "c", model: "m" }; // init only after input
        yield { type: "result", subtype: "success", total_cost_usd: 0 };
      }
    })();
    gen.supportedCommands = async () => RAW;
    return gen;
  };
  const db = openDb(":memory:");
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES ('p','/tmp','p','unknown')").run();
  db.prepare("INSERT INTO sessions (id, project_id, kind, status, created_at) VALUES ('s','p','claude','live',?)").run(new Date().toISOString());
  const ws = fakeWs();
  const s = new ClaudeSession(db, "s", "/tmp", queryFn as any);
  s.attach(ws);
  s.start();
  await waitFor(() => ws.frames.some((f: any) => f.t === "commands"));
  assert.equal(ws.frames.some((f: any) => f.t === "init"), false, "no init yet — and the commands are already here");
});

test("if the skills list can't be read, only non-built-in commands are offered (no built-ins leak)", async () => {
  const queryFn = (params: { prompt: AsyncIterable<any>; options: any }) => {
    if (!params.options?.canUseTool) return (async function* () {})();
    const gen: any = (async function* () { for await (const _ of params.prompt) yield { type: "result", subtype: "success", total_cost_usd: 0 }; })();
    gen.supportedCommands = async () => RAW;
    gen.getContextUsage = async () => { throw new Error("no context"); };
    return gen;
  };
  const db = openDb(":memory:");
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES ('p','/tmp','p','unknown')").run();
  db.prepare("INSERT INTO sessions (id, project_id, kind, status, created_at) VALUES ('s','p','claude','live',?)").run(new Date().toISOString());
  const ws = fakeWs();
  const s = new ClaudeSession(db, "s", "/tmp", queryFn as any);
  s.attach(ws);
  s.start();
  await waitFor(() => ws.frames.some((f: any) => f.t === "commands"));
  assert.deepEqual(ws.frames.find((f: any) => f.t === "commands").commands.map((c: any) => c.name), ["deploy", "simplify", "stripe:test-cards"]);
});
