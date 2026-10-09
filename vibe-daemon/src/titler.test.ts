// Auto-titler verification (ADR 0009). Pure helpers get exercised directly; the
// LLM refine runs against a FAKE queryFn — no `claude` subprocess, no spend.

import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { openDb } from "./db.js";
import {
  MAX_TITLE,
  cleanText,
  composeTitle,
  currentTitle,
  heuristicBody,
  projectPrefix,
  refineTitle,
  sanitizeLlmTitle,
  titleOnFirstUserTurn,
} from "./titler.js";

function seedDb() {
  const db = openDb(":memory:");
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES (?,?,?,?)").run("p1", "/tmp/vibemobile", "p", "unknown");
  db.prepare("INSERT INTO sessions (id, project_id, kind, status, created_at) VALUES (?,?,?,?,?)").run(
    "s1",
    "p1",
    "claude",
    "live",
    new Date().toISOString(),
  );
  return db;
}

// Engines call titleOnFirstUserTurn right AFTER inserting the user row.
function pushUserRow(db: ReturnType<typeof seedDb>, text: string) {
  db.prepare("INSERT INTO messages (id, session_id, role, content, ts) VALUES (?,?,?,?,?)").run(
    randomUUID(),
    "s1",
    "user",
    text,
    new Date().toISOString(),
  );
}

const collector = () => {
  const frames: any[] = [];
  return { frames, emit: (f: any) => frames.push(f) };
};

const titleOf = (db: ReturnType<typeof seedDb>) => currentTitle(db, "s1");

// ---- pure ----------------------------------------------------------------

test("projectPrefix takes the dir name, tolerating trailing slashes and /", () => {
  assert.equal(projectPrefix("/home/user/vibemobile"), "vibemobile");
  assert.equal(projectPrefix("/home/user/vibemobile///"), "vibemobile");
  assert.equal(projectPrefix("/"), "chat");
  assert.equal(projectPrefix(""), "chat");
});

test("cleanText keeps the first prose line and drops code/markup noise", () => {
  assert.equal(cleanText("rename the sessions\nand also the tags"), "rename the sessions");
  assert.equal(cleanText("\n\n  fix the parser  "), "fix the parser");
  assert.equal(cleanText("```ts\nconst x = 1;\n```\nexplain this"), "explain this");
  assert.equal(cleanText("read [the docs](https://x.dev) now"), "read the docs now");
  assert.equal(cleanText("wrap `foo()` in a try"), "wrap foo() in a try");
});

test("cleanText collapses NBSP, tabs and control chars", () => {
  assert.equal(cleanText("a  b\tcd"), "a b c d");
});

test("cleanText cuts at the first sentence only when enough words remain", () => {
  assert.equal(cleanText("add auto titles to sessions. then ship it"), "add auto titles to sessions");
  assert.equal(cleanText("do it. right now please"), "do it. right now please"); // 2 words → keep whole
});

test("cleanText strips a leading slash command but keeps a bare one", () => {
  assert.equal(cleanText("/plan add auto titles"), "add auto titles");
  assert.equal(cleanText("/commit"), "/commit");
});

test("heuristicBody falls back when the turn has no text (images-only)", () => {
  assert.equal(heuristicBody(""), "New chat");
  assert.equal(heuristicBody("   \n\t "), "New chat");
});

test("composeTitle prefixes the dir and capitalizes the body", () => {
  assert.equal(composeTitle("vibemobile", "add auto titles"), "vibemobile · Add auto titles");
});

test("composeTitle truncates at a word boundary within MAX_TITLE", () => {
  const t = composeTitle("vibemobile", "the titles of our claude sessions are just the session id and that is useless");
  assert.ok(Array.from(t).length <= MAX_TITLE, t);
  assert.ok(t.endsWith("…"), t);
  assert.ok(!/ …$/.test(t), t); // no dangling space before the ellipsis
});

test("composeTitle never splits an emoji or CJK char", () => {
  const t = composeTitle("vibemobile", "🚀".repeat(80));
  assert.ok(Array.from(t).length <= MAX_TITLE);
  assert.equal(Buffer.from(t, "utf8").toString("utf8"), t); // no lone surrogate
  const cjk = composeTitle("vibemobile", "会话标题自动生成".repeat(20));
  assert.ok(Array.from(cjk).length <= MAX_TITLE);
  assert.equal(Buffer.from(cjk, "utf8").toString("utf8"), cjk);
});

test("composeTitle degrades gracefully when the dir name eats the budget", () => {
  const t = composeTitle("d".repeat(90), "add auto titles");
  assert.ok(Array.from(t).length <= MAX_TITLE, t);
  assert.ok(t.endsWith("New chat"), t);
});

test("sanitizeLlmTitle strips quotes/periods and rejects junk", () => {
  assert.equal(sanitizeLlmTitle('"Add auto titles."'), "Add auto titles");
  assert.equal(sanitizeLlmTitle("Add auto titles"), "Add auto titles");
  assert.equal(sanitizeLlmTitle(""), null);
  assert.equal(sanitizeLlmTitle("   "), null);
  assert.equal(sanitizeLlmTitle("Here is a title:\nAdd auto titles\nHope that helps"), null);
  assert.equal(sanitizeLlmTitle("word ".repeat(200)), null);
});

// ---- heuristic write -----------------------------------------------------

test("first user turn writes an auto title and emits one frame", () => {
  const db = seedDb();
  const { frames, emit } = collector();
  pushUserRow(db, "the titles of our sessions are just the session id");
  const prompt = titleOnFirstUserTurn(db, "s1", "/tmp/vibemobile", "the titles of our sessions are just the session id", emit);

  assert.ok(prompt);
  const row = db.prepare("SELECT title, title_auto FROM sessions WHERE id = 's1'").get() as any;
  assert.ok(row.title.startsWith("vibemobile · "), row.title);
  assert.equal(row.title_auto, 1);
  assert.deepEqual(frames, [{ t: "title", title: row.title, auto: true }]);
});

test("second user turn never re-titles", () => {
  const db = seedDb();
  const { emit } = collector();
  pushUserRow(db, "first");
  titleOnFirstUserTurn(db, "s1", "/tmp/vibemobile", "first", emit);
  const after = titleOf(db);

  const { frames, emit: emit2 } = collector();
  pushUserRow(db, "second");
  assert.equal(titleOnFirstUserTurn(db, "s1", "/tmp/vibemobile", "second", emit2), null);
  assert.equal(titleOf(db), after);
  assert.deepEqual(frames, []);
});

test("a title set at create time wins", () => {
  const db = seedDb();
  db.prepare("UPDATE sessions SET title = 'build logs' WHERE id = 's1'").run();
  const { frames, emit } = collector();
  pushUserRow(db, "hi");
  assert.equal(titleOnFirstUserTurn(db, "s1", "/tmp/vibemobile", "hi", emit), null);
  assert.equal(titleOf(db), "build logs");
  assert.deepEqual(frames, []);
});

test("VIBE_AUTO_TITLE=0 disables the whole feature", () => {
  const db = seedDb();
  const { frames, emit } = collector();
  process.env.VIBE_AUTO_TITLE = "0";
  try {
    pushUserRow(db, "hi");
    assert.equal(titleOnFirstUserTurn(db, "s1", "/tmp/vibemobile", "hi", emit), null);
  } finally {
    delete process.env.VIBE_AUTO_TITLE;
  }
  assert.equal(titleOf(db), null);
  assert.deepEqual(frames, []);
});

// ---- LLM refine ----------------------------------------------------------

// Records the options it was called with, then yields a canned result.
function fakeQuery(result: any) {
  const calls: any[] = [];
  const fn = (params: any) => {
    calls.push(params);
    return (async function* () {
      if (result instanceof Error) throw result;
      yield { type: "system", subtype: "init", session_id: "x" };
      yield { type: "result", subtype: "success", result };
    })();
  };
  return { fn, calls };
}

function withHeuristic() {
  const db = seedDb();
  const { frames, emit } = collector();
  pushUserRow(db, "the titles of our sessions are just the session id");
  const prompt = titleOnFirstUserTurn(db, "s1", "/tmp/vibemobile", "the titles of our sessions are just the session id", emit)!;
  const heuristic = titleOf(db)!;
  frames.length = 0;
  return { db, frames, emit, prompt, heuristic };
}

test("refine replaces the heuristic and re-emits, in an isolated tool-less call", async () => {
  const { db, frames, emit, prompt } = withHeuristic();
  const { fn, calls } = fakeQuery("Auto-name chat sessions");
  await refineTitle(db, "s1", "/tmp/vibemobile", prompt, emit, fn);

  const row = db.prepare("SELECT title, title_auto FROM sessions WHERE id = 's1'").get() as any;
  assert.equal(row.title, "vibemobile · Auto-name chat sessions");
  assert.equal(row.title_auto, 1); // still auto — a manual rename can still pin it
  assert.deepEqual(frames, [{ t: "title", title: row.title, auto: true }]);

  const opts = calls[0].options;
  assert.deepEqual(opts.settingSources, []); // no CLAUDE.md / settings / file hooks
  assert.deepEqual(opts.tools, []); // no filesystem, no shell
  assert.equal(opts.maxTurns, 1);
  assert.equal(opts.persistSession, false); // no transcript → never listed as a session
  assert.equal(opts.cwd, "/tmp/vibemobile");
  assert.notEqual(opts.permissionMode, "bypassPermissions");
  assert.ok(String(calls[0].prompt).includes("the titles of our sessions"));
});

test("refine is fail-soft: a throwing SDK leaves the heuristic", async () => {
  const { db, frames, emit, prompt, heuristic } = withHeuristic();
  const { fn } = fakeQuery(new Error("model not found"));
  await refineTitle(db, "s1", "/tmp/vibemobile", prompt, emit, fn);
  assert.equal(titleOf(db), heuristic);
  assert.deepEqual(frames, []);
});

test("refine rejects junk output", async () => {
  for (const junk of ["", "   ", "Sure!\nAdd auto titles\nLet me know", "word ".repeat(200)]) {
    const { db, frames, emit, prompt, heuristic } = withHeuristic();
    const { fn } = fakeQuery(junk);
    await refineTitle(db, "s1", "/tmp/vibemobile", prompt, emit, fn);
    assert.equal(titleOf(db), heuristic, `junk: ${junk.slice(0, 20)}`);
    assert.deepEqual(frames, []);
  }
});

test("a manual rename mid-flight pins the title", async () => {
  const { db, frames, emit, prompt, heuristic } = withHeuristic();
  db.prepare("UPDATE sessions SET title_auto = 0 WHERE id = 's1'").run(); // PATCH /sessions/:id
  const { fn, calls } = fakeQuery("Auto-name chat sessions");
  await refineTitle(db, "s1", "/tmp/vibemobile", prompt, emit, fn);
  assert.equal(titleOf(db), heuristic);
  assert.equal(calls.length, 0); // pinned before the call — no spend at all
  assert.deepEqual(frames, []);
});

test("VIBE_AUTO_TITLE_LLM=0 and the in-flight cap skip the model call", async () => {
  for (const env of [["VIBE_AUTO_TITLE_LLM", "0"], ["VIBE_TITLE_MAX_INFLIGHT", "0"]] as const) {
    const { db, frames, emit, prompt, heuristic } = withHeuristic();
    const { fn, calls } = fakeQuery("Auto-name chat sessions");
    process.env[env[0]] = env[1];
    try {
      await refineTitle(db, "s1", "/tmp/vibemobile", prompt, emit, fn);
    } finally {
      delete process.env[env[0]];
    }
    assert.equal(calls.length, 0, env[0]);
    assert.equal(titleOf(db), heuristic);
    assert.deepEqual(frames, []);
  }
});
