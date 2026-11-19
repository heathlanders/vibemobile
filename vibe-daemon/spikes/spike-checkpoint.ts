// Spike (proposal 27/28, ADR 0023) — prove, against the REAL Agent SDK, how file
// checkpointing + rewind behave over streaming input:
//  (a) enableFileCheckpointing + a caller-minted SDKUserMessage.uuid is honored
//      (the uuid we pass is the one rewindFiles accepts)
//  (b) two turns of edits, dryRun rewind to turn 1 reports turn-2 changes only
//  (c) real rewind restores files to the turn-1 state
//  (d) a file created via Bash is NOT touched by rewind
//  (e) cwd = a git worktree works
//  (f) [resume] after the first query ends, `resume` + rewindFiles still works
// Usage: tsx src/spike-checkpoint.ts [worktree]   (cwd is a throwaway temp dir)
// Spends a few cents of real Claude usage. Never run against a real project.

import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { existsSync, mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { query } from "@anthropic-ai/claude-agent-sdk";

const useWorktree = process.argv[2] === "worktree";
const base = mkdtempSync(join(tmpdir(), "spike-ckpt-"));
let cwd = base;
if (useWorktree) {
  const git = (...a: string[]) => execFileSync("git", ["-C", base, ...a], { stdio: "pipe" });
  git("init", "-q");
  git("-c", "user.name=s", "-c", "user.email=s@s", "commit", "--allow-empty", "-qm", "init");
  cwd = join(base, ".vibe-worktrees", "w1");
  git("worktree", "add", "--no-track", "-b", "vibe/w1", "--", cwd, "HEAD");
}
console.log(`[spike] cwd=${cwd} worktree=${useWorktree}`);

type Run = { q: any; it: AsyncIterator<any>; push: (text: string, uuid: string) => void; close: () => void; sessionId?: string };

function start(resume?: string): Run {
  const queue: any[] = [];
  let wake: (() => void) | null = null;
  let closed = false;
  async function* input() {
    while (!closed) {
      while (queue.length) yield queue.shift();
      if (closed) break;
      await new Promise<void>((r) => (wake = r));
    }
  }
  const q = query({
    prompt: input(),
    options: {
      cwd,
      permissionMode: "acceptEdits",
      enableFileCheckpointing: true,
      resume,
      maxTurns: 6,
      canUseTool: async (_n: string, i: Record<string, unknown>) => ({ behavior: "allow", updatedInput: i }),
    } as any,
  });
  return {
    q,
    it: (q as AsyncGenerator<any>)[Symbol.asyncIterator](),
    push: (text, uuid) => {
      queue.push({ type: "user", message: { role: "user", content: text }, parent_tool_use_id: null, uuid });
      wake?.();
      wake = null;
    },
    close: () => {
      closed = true;
      wake?.();
    },
  };
}

// Drain until `n` results seen; capture session id + any user-message uuids echoed.
// NOTE: manual iterator — `return` inside for-await would close the Query.
async function drain(run: Run, n: number, echoed: string[]) {
  let seen = 0;
  for (;;) {
    const { value: msg, done } = await run.it.next();
    if (done) return;
    if (msg.session_id) run.sessionId = msg.session_id;
    if (msg.type === "user" && msg.uuid && !Array.isArray(msg.message?.content)) echoed.push(msg.uuid);
    if (msg.type === "user" && msg.uuid && Array.isArray(msg.message?.content) && msg.message.content.some((b: any) => b.type === "text"))
      echoed.push(msg.uuid);
    if (msg.type === "result") {
      console.log(`[result] subtype=${msg.subtype}`);
      if (++seen >= n) return;
    }
  }
}

const read = (f: string) => (existsSync(join(cwd, f)) ? readFileSync(join(cwd, f), "utf8").trim() : "<missing>");
const ok = (name: string, cond: boolean) => console.log(`${cond ? "PASS" : "FAIL"} ${name}`);

const u1 = randomUUID();
const u2 = randomUUID();
const echoed: string[] = [];
const run = start();

run.push("Use the Write tool to create a.txt containing exactly 'one'. Nothing else.", u1);
await drain(run, 1, echoed);
console.log(`[turn1] a.txt=${read("a.txt")}`);

run.push(
  "Use the Write tool to overwrite a.txt with exactly 'two', and Write b.txt with exactly 'bee'. " +
    "Then use Bash to run: echo bash > c.txt . Nothing else.",
  u2,
);
await drain(run, 1, echoed);
console.log(`[turn2] a=${read("a.txt")} b=${read("b.txt")} c=${read("c.txt")}`);

// (a) the uuid WE minted is accepted by rewindFiles (the SDK does not echo input
// user messages unless replayUserMessages is set, so test acceptance, not echo).
const dry = await run.q.rewindFiles(u1, { dryRun: true });
console.log(`[dry u1] ${JSON.stringify(dry)}`);
ok("(a) caller-minted uuid accepted by rewindFiles", dry.canRewind === true);
ok("(b) dryRun lists changed files", (dry.filesChanged?.length ?? 0) >= 1);
ok("(b) dryRun did not modify files", read("a.txt") === "two" && read("b.txt") === "bee");

// Semantics probe: rewind to u2 = state BEFORE turn-2's edits.
const toU2 = await run.q.rewindFiles(u2);
console.log(`[real u2] ${JSON.stringify(toU2)} a=${read("a.txt")} b=${read("b.txt")} c=${read("c.txt")}`);
ok("(c) rewind(u2): a.txt back to turn-1 content 'one'", read("a.txt") === "one");
ok("(c) rewind(u2): b.txt (created in turn 2) removed", read("b.txt") === "<missing>");
ok("(d) rewind(u2): Bash-created c.txt untouched", read("c.txt") === "bash");

const toU1 = await run.q.rewindFiles(u1);
console.log(`[real u1] ${JSON.stringify(toU1)} a=${read("a.txt")}`);
ok("(c2) rewind(u1): a.txt (created in turn 1) removed => rewind(u) undoes u's own edits", read("a.txt") === "<missing>");

run.close();
const sid = run.sessionId;
console.log(`[spike] session=${sid}; testing resume`);

// (f) fresh query with resume: new edit, then rewind to it; and is a pre-resume checkpoint still known?
if (sid) {
  const run2 = start(sid);
  const u3 = randomUUID();
  run2.push("Use the Write tool to create d.txt containing exactly 'dee'. Nothing else.", u3);
  await drain(run2, 1, []);
  console.log(`[resume] d.txt=${read("d.txt")}`);
  try {
    const pre = await run2.q.rewindFiles(u1, { dryRun: true });
    console.log(`[resume dry u1 (pre-resume)] ${JSON.stringify(pre)}`);
    ok("(f1) pre-resume checkpoint reachable after resume", pre.canRewind === true);
    const post = await run2.q.rewindFiles(u3);
    console.log(`[resume real u3] ${JSON.stringify(post)} d=${read("d.txt")}`);
    ok("(f2) post-resume edit rewindable", read("d.txt") === "<missing>");
  } catch (e: any) {
    console.log(`[resume] rewindFiles threw: ${String(e?.message).slice(0, 200)}`);
    ok("(f) rewind after resume", false);
  }
  run2.close();
}
console.log(`[spike] DONE (tmp dir left at ${base})`);
