// Auto-titled chat sessions (ADR 0009). Without this a session's label is its
// raw id (`s_ab12…`) — the Flutter `label` getter is `title ?? id` — which is
// useless once the multi-chat grid holds six of them.
//
// Hybrid + fail-soft. A pure heuristic runs synchronously on the FIRST user turn
// so a raw id is never shown, then one cheap tool-less LLM call refines it. Any
// LLM failure (timeout, bad model, junk output) leaves the heuristic standing —
// titling is never on a turn's critical path.
//
// First turn only: the guard is "exactly one user row in `messages`", so a
// session is never re-titled as the chat drifts. A manual PATCH /sessions/:id
// clears `sessions.title_auto`, pinning the title for good (sessions.ts).
//
// The refine call runs in SDK isolation mode (`settingSources: []`, `tools: []`)
// so the project's CLAUDE.md, settings, hooks and MCP servers never leak into a
// throwaway summarization — and it can't touch the filesystem.

import { basename } from "node:path";
import { query as sdkQuery } from "@anthropic-ai/claude-agent-sdk";
import type { DB } from "./db.js";
import { logEvent } from "./auth.js";
import { gatewayEnv } from "./gateway.js";

type QueryFn = (params: { prompt: string | AsyncIterable<any>; options: any }) => AsyncGenerator<any>;
type Emit = (frame: Record<string, unknown>) => void;

export const TITLE_SEP = " · ";
export const MAX_TITLE = 60; // total code points, dir prefix included
const FALLBACK_BODY = "New chat";
const FALLBACK_PREFIX = "chat";
const PROMPT_CHARS = 2000; // how much of the first turn the model sees
// Exported so discover.ts can recognise (and hide) transcripts these calls left
// behind before `persistSession: false`.
export const TITLE_PROMPT_HEAD = "Summarize this coding request as a chat title:";

// Read per-call (like maxLive() in sessions.ts) so the unit env retunes without a rebuild.
const enabled = () => process.env.VIBE_AUTO_TITLE !== "0";
const llmEnabled = () => enabled() && process.env.VIBE_AUTO_TITLE_LLM !== "0";
const titleModel = () => process.env.VIBE_TITLE_MODEL ?? "claude-haiku-4-5";
const titleTimeoutMs = () => Number(process.env.VIBE_TITLE_TIMEOUT_MS ?? 20_000);
const maxInFlight = () => Number(process.env.VIBE_TITLE_MAX_INFLIGHT ?? 2);
let inFlight = 0;

// ---- pure helpers --------------------------------------------------------

// Project dir name for the title prefix. Trailing slashes and '/' both degrade
// to the fallback rather than producing an empty prefix.
export function projectPrefix(cwd: string): string {
  return basename(cwd.replace(/\/+$/, "")) || FALLBACK_PREFIX;
}

// Squash a raw prompt into one line of plain prose. Order matters.
export function cleanText(raw: string): string {
  let s = raw
    .replace(/[\u200b-\u200d\ufeff]/g, "") // BOM + zero-width
    .replace(/```[\s\S]*?```/g, " ") // fenced code
    .replace(/`/g, "") // inline-code delimiters
    .replace(/!?\[([^\]]*)\]\([^)]*\)/g, "$1"); // markdown links → label
  s = s.split("\n").find((l) => l.trim()) ?? "";
  // Leading slash command (/plan, /caveman:commit) — drop it only if prose follows.
  s = s.replace(/^\/[\w:-]+\s+(?=\S)/, "");
  s = s
    .replace(/[\u0000-\u001f\u007f]/g, " ") // control chars
    .replace(/[\s\u00a0]+/g, " ") // collapse whitespace incl. NBSP
    .trim();
  // First sentence, when that still leaves something substantial.
  const stop = s.search(/[.!?](\s|$)/);
  if (stop > 0) {
    const head = s.slice(0, stop).trim();
    if (head.split(" ").length >= 3) s = head;
  }
  return s;
}

export function heuristicBody(prompt: string): string {
  return cleanText(prompt) || FALLBACK_BODY;
}

// "<dir> · <body>", capped at MAX_TITLE. All slicing is over code points so an
// emoji or CJK char is never cut in half into a lone surrogate.
export function composeTitle(prefix: string, body: string): string {
  const chars = (s: string) => Array.from(s);
  let head = prefix || FALLBACK_PREFIX;
  let budget = MAX_TITLE - chars(head).length - TITLE_SEP.length;
  if (budget < 12) {
    // Pathologically long dir name: truncate the prefix and keep a minimal body.
    head = chars(head).slice(0, MAX_TITLE - TITLE_SEP.length - chars(FALLBACK_BODY).length).join("");
    body = FALLBACK_BODY;
    budget = chars(FALLBACK_BODY).length;
  }
  const cs = chars(body);
  let tail = body;
  if (cs.length > budget) {
    const cut = cs.slice(0, budget - 1).join("");
    const space = cut.lastIndexOf(" ");
    tail = (space > budget / 2 ? cut.slice(0, space) : cut).trimEnd() + "…";
  }
  tail = chars(tail).length ? chars(tail)[0].toUpperCase() + chars(tail).slice(1).join("") : FALLBACK_BODY;
  return head + TITLE_SEP + tail;
}

// The model's raw text never reaches the DB unchecked: strip wrapping quotes and
// a trailing period, then reject anything that isn't a plausible short title.
export function sanitizeLlmTitle(raw: string | null | undefined): string | null {
  if (!raw) return null;
  if (/\n\s*\S[\s\S]*\n/.test(raw.trim())) return null; // multi-line ⇒ it ignored the instruction
  let s = cleanText(raw);
  s = s.replace(/^["'“”‘’]+|["'“”‘’]+$/g, "").replace(/\.+$/, "").trim();
  if (!s) return null;
  if (Array.from(s).length > 4 * MAX_TITLE) return null; // rambled
  return s;
}

// ---- DB entry points -----------------------------------------------------

// Fire on the FIRST user turn only, AFTER the user row is inserted. Returns the
// prompt to refine with, or null if it didn't fire (already titled, not the
// first turn, feature off).
export function titleOnFirstUserTurn(
  db: DB,
  sessionId: string,
  cwd: string,
  text: string,
  emit: Emit,
): string | null {
  if (!enabled()) return null;
  const { n } = db
    .prepare("SELECT COUNT(*) AS n FROM messages WHERE session_id = ? AND role = 'user'")
    .get(sessionId) as { n: number };
  if (n !== 1) return null;
  const title = composeTitle(projectPrefix(cwd), heuristicBody(text));
  // Guarded: a title supplied at create time wins and is never auto-overwritten.
  const info = db
    .prepare("UPDATE sessions SET title = ?, title_auto = 1 WHERE id = ? AND title IS NULL")
    .run(title, sessionId);
  if (info.changes === 0) return null;
  emit({ t: "title", title, auto: true });
  return text;
}

// One-shot LLM refine. Fire-and-forget: never awaited by a turn, never throws.
export async function refineTitle(
  db: DB,
  sessionId: string,
  cwd: string,
  prompt: string,
  emit: Emit,
  queryFn: QueryFn = sdkQuery as unknown as QueryFn,
): Promise<void> {
  if (!llmEnabled() || inFlight >= maxInFlight()) return;
  const row = db.prepare("SELECT title_auto FROM sessions WHERE id = ?").get(sessionId) as
    | { title_auto: number }
    | undefined;
  if (!row?.title_auto) return; // pinned by a manual rename, or gone

  inFlight++;
  const ac = new AbortController();
  const timer = setTimeout(() => ac.abort(), titleTimeoutMs());
  timer.unref?.();
  try {
    const q = queryFn({
      prompt:
        TITLE_PROMPT_HEAD +
        " 5 words max, imperative " +
        "mood, no quotes, no trailing period, plain text only. Reply with the " +
        "title and nothing else.\n\n<request>\n" +
        Array.from(prompt).slice(0, PROMPT_CHARS).join("") +
        "\n</request>",
      options: {
        model: titleModel(),
        // A plain-string systemPrompt REPLACES the claude_code preset — this is a
        // summarizer, not an agent.
        systemPrompt: "You write terse chat titles. Output only the title.",
        // [] = SDK isolation: no ~/.claude settings, no project settings, no
        // CLAUDE.md, no file-configured hooks bleeding into a title.
        settingSources: [],
        tools: [], // the actual restriction knob (allowedTools only auto-allows)
        allowedTools: [],
        skills: [],
        plugins: [],
        mcpServers: {},
        strictMcpConfig: true,
        maxTurns: 1,
        // No ~/.claude/projects/<cwd>/*.jsonl — else discover.ts lists this
        // throwaway call as a session in the project's tab.
        persistSession: false,
        includePartialMessages: false,
        permissionMode: "default", // never bypassPermissions (security.md)
        cwd,
        env: gatewayEnv(),
        abortController: ac,
      },
    });
    let out: string | null = null;
    for await (const msg of q) {
      if (msg?.type === "result" && msg.subtype === "success") out = msg.result ?? null;
    }
    const body = sanitizeLlmTitle(out);
    if (!body) return;
    const title = composeTitle(projectPrefix(cwd), body);
    const info = db.prepare("UPDATE sessions SET title = ? WHERE id = ? AND title_auto = 1").run(title, sessionId);
    if (info.changes === 0) return; // a manual rename raced in — it's pinned now
    logEvent(db, "session.autotitle", null, sessionId);
    emit({ t: "title", title, auto: true });
  } catch {
    // fail-soft: the heuristic title stands
  } finally {
    clearTimeout(timer);
    inFlight--;
  }
}

// Re-emit the stored title to a freshly attached socket. Needed because a
// create-with-prompt session (proposal 15) is primed BEFORE attach, so its
// heuristic frame is written while no socket exists.
export function currentTitle(db: DB, sessionId: string): string | null {
  const row = db.prepare("SELECT title FROM sessions WHERE id = ?").get(sessionId) as
    | { title: string | null }
    | undefined;
  return row?.title ?? null;
}
