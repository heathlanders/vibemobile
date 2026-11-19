// Spike — conversation fork ("branch from here") over the Agent SDK.
//  (a) does the transcript keep the uuid we supplied on a streamed user message?
//  (b) what do getSessionMessages() rows look like (to find the end of a turn)?
//  (c) forkSession({upToMessageId}) -> does a resumed fork remember exactly the turns up to the cut?
//  (d) does the original stay untouched?
// Usage: tsx src/spike-fork.ts   (temp cwd, a few cents)
import { randomUUID } from "node:crypto";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { forkSession, getSessionMessages, query } from "@anthropic-ai/claude-agent-sdk";

const cwd = mkdtempSync(join(tmpdir(), "spike-fork-"));
const u1 = randomUUID(), u2 = randomUUID();
const queue: any[] = []; let wake: (() => void) | null = null; let closed = false;
const push = (text: string, uuid: string) => { queue.push({ type: "user", message: { role: "user", content: text }, parent_tool_use_id: null, uuid }); wake?.(); wake = null; };
async function* input() { while (!closed) { while (queue.length) yield queue.shift(); if (closed) break; await new Promise<void>((r) => (wake = r)); } }
const q: any = query({ prompt: input(), options: { cwd, permissionMode: "default", canUseTool: async (_n: string, i: any) => ({ behavior: "allow", updatedInput: i }) } as any });
const it = q[Symbol.asyncIterator]();
let sid = ""; let turn = 0;
push("Remember the secret word PINEAPPLE. Reply only: noted.", u1);
for (;;) {
  const { value: m, done } = await it.next();
  if (done) break;
  if (m.session_id) sid = m.session_id;
  if (m.type === "result") {
    turn++;
    if (turn === 1) push("Now remember the second secret word TURQUOISE. Reply only: noted.", u2);
    else { closed = true; wake?.(); break; }
  }
}
console.log("session", sid);
const msgs: any[] = await getSessionMessages(sid, { dir: cwd });
console.log("(b) getSessionMessages rows:", msgs.map((m) => `${m.type}:${String(m.uuid).slice(0, 8)}`).join("  "));
console.log("(a) our uuids present in transcript: u1=", msgs.some((m) => m.uuid === u1), " u2=", msgs.some((m) => m.uuid === u2));

// cut = the message just BEFORE the second user turn  => keeps turn 1 and its reply only
const iU2 = msgs.findIndex((m) => m.uuid === u2);
const cut = msgs[iU2 - 1].uuid;
const fork = await forkSession(sid, { dir: cwd, upToMessageId: cut, title: "spike fork" });
console.log("(c) forked", fork.sessionId, "up to", String(cut).slice(0, 8), "(" + msgs[iU2 - 1].type + ")");
const fm: any[] = await getSessionMessages(fork.sessionId, { dir: cwd });
console.log("    fork has", fm.length, "messages vs original", msgs.length, "| fork mentions TURQUOISE:", JSON.stringify(fm).includes("TURQUOISE"), "| PINEAPPLE:", JSON.stringify(fm).includes("PINEAPPLE"));

// resume the fork and ask what it remembers
const q2: any = query({ prompt: (async function* () { yield { type: "user", message: { role: "user", content: "List every secret word I told you, comma separated, or say NONE." }, parent_tool_use_id: null }; await new Promise(() => {}); })(), options: { cwd, resume: fork.sessionId, permissionMode: "default", canUseTool: async (_n: string, i: any) => ({ behavior: "allow", updatedInput: i }) } as any });
let reply = "";
for await (const m of q2 as AsyncGenerator<any>) {
  if (m.type === "assistant") for (const b of m.message?.content ?? []) if (b.type === "text") reply += b.text;
  if (m.type === "result") break;
}
console.log("    fork remembers:", JSON.stringify(reply));
const orig: any[] = await getSessionMessages(sid, { dir: cwd });
console.log("(d) original still has", orig.length, "messages (was", msgs.length + ")");
process.exit(0);
