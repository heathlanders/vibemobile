// "Improve prompt" (ADR 0018). One tool-less, isolated Agent SDK call rewrites a
// prompt against a coding-agent prompting checklist (docs/prompting-guide.md).
// Same lockdown as the auto-titler (titler.ts): no settings, CLAUDE.md, hooks,
// MCP, skills or tools — it can only return text. The user reviews the rewrite
// before anything uses it.

import { query as sdkQuery } from "@anthropic-ai/claude-agent-sdk";
import { gatewayEnv } from "./gateway.js";

type QueryFn = (params: { prompt: string; options: any }) => AsyncGenerator<any>;

export const MAX_PROMPT_CHARS = 20_000;
const model = () => process.env.VIBE_IMPROVE_MODEL ?? "claude-sonnet-4-6";
const timeoutMs = () => Number(process.env.VIBE_IMPROVE_TIMEOUT_MS ?? 60_000);
const MAX_IN_FLIGHT = 2;
let inFlight = 0;

export const IMPROVE_SYSTEM = `You rewrite prompts that a developer will send to an AI coding agent.
Make the prompt clearer and more effective without changing what the author wants.

Checklist:
- Lead with the goal and, if known, why it matters.
- Make success checkable: tests to pass, behaviour to observe, output to produce.
- Keep every concrete detail the author gave: file paths, symbols, error messages, commands, versions. Quote errors verbatim.
- State scope: what to change and what to leave alone.
- Keep constraints explicit (style, dependencies, performance, security).
- For multi-step work, order the steps, or ask for a short plan before editing.
- If something is ambiguous, tell the agent to ask instead of guessing.
- Cut filler, pleasantries and repetition; shorter is better when nothing is lost.
- Never invent facts, files or requirements the author didn't state.
- Preserve {{placeholders}} exactly as written.

Reply with the rewritten prompt only — no preamble, no commentary, no code fences around it.`;

// "Go deeper" mode (proposal 61): Felix Rieseberg's depth meta-prompt, adapted to a coding agent.
export const DEEPER_SYSTEM = `You rewrite prompts that a developer will send to an AI coding agent, to make them deeper, not bigger.

Work through these steps silently, then write the rewrite:
1. What would a top professional in this field do with this task?
2. Which rawest material should the agent start from (logs, data, source, the real system) rather than summaries?
3. Which specific methods or tools fit (real tests, profilers, databases, statistics, another discipline's techniques)?
4. What external evidence would show the result is right (a test run, real output, a measurement), so the agent need not judge its own work?

Then rewrite the prompt so it asks for exactly that.
- Keep the author's goal and every concrete detail (file paths, symbols, errors, commands, versions).
- Never add scope: no extra features, files or deliverables the author didn't ask for. Depth and verification only.
- Never invent facts, files or requirements the author didn't state.
- Preserve {{placeholders}} exactly as written.

Reply with the rewritten prompt only — no preamble, no commentary, no code fences around it.`;

export type ImproveMode = "improve" | "deeper";

export class ImproveBusy extends Error {}

// Rewrite [text]; throws ImproveBusy when too many are running, or on failure.
export async function improvePrompt(text: string, cwd: string, queryFn: QueryFn = sdkQuery as unknown as QueryFn, mode: ImproveMode = "improve"): Promise<string> {
  if (inFlight >= MAX_IN_FLIGHT) throw new ImproveBusy("busy");
  inFlight++;
  const ac = new AbortController();
  const timer = setTimeout(() => ac.abort(), timeoutMs());
  timer.unref?.();
  try {
    const q = queryFn({
      prompt: `<prompt>\n${text}\n</prompt>`,
      options: {
        model: model(),
        systemPrompt: mode === "deeper" ? DEEPER_SYSTEM : IMPROVE_SYSTEM, // replaces the claude_code preset — a rewriter, not an agent
        settingSources: [],
        tools: [],
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
    const cleaned = (out ?? "").trim().replace(/^```[a-z]*\n([\s\S]*)\n```$/, "$1").trim();
    if (!cleaned) throw new Error("no rewrite returned");
    return cleaned;
  } finally {
    clearTimeout(timer);
    inFlight--;
  }
}
