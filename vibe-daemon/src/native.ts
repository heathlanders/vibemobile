// Native multi-provider engine (ADR 0008). Runs non-Claude models (OpenAI now,
// Gemini later) AS THEMSELVES via the Vercel AI SDK — their own native tool-calling
// and agent loop — while emitting the SAME claude-ws.md frames as ClaudeSession, so
// the Flutter chat UI, the WS handler, persistence, and the reaper are unchanged.
//
// Differences from ClaudeSession (claude.ts):
//  - Stateless HTTP: no claude_session_id. The conversation lives in an in-memory
//    ModelMessage[] loaded from the `messages` table; resume = transcript replay.
//  - Tool permissions run through the SAME shared gate (permission-gate.ts). A native
//    tool that skips gate.request() is a shell-over-network hole (security.md #11).
//  - `streamTextFn` is injectable so tests drive a fake AI SDK — no real API call,
//    no spend (the analog of ClaudeSession's `queryFn`).
//
// Loose typing (SdkPart = any) mirrors claude.ts — the AI SDK's generics are large,
// and the fullStream part names are pinned by the M6 spike + the fake-model tests.

import { randomUUID } from "node:crypto";
import { streamText as realStreamText, stepCountIs, type ModelMessage } from "ai";
import { priceFor, providerFor, upstreamModel } from "./gateway.js";
import { nativeModel } from "./providers.js";
import { recordUsage } from "./spend.js";
import { capHistory } from "./history.js";
import type { WebSocket } from "ws";
import type { DB } from "./db.js";
import { logEvent } from "./auth.js";
import { PermissionGate } from "./permission-gate.js";
import { notifyDevices, type PushType } from "./push.js";
import { DEFAULT_MODE, type EngineSession, type SessionMode } from "./engine.js";
import { buildNativeTools, nativeTier } from "./native-tools.js";
import { TurnStatus } from "./turn-status.js";
import { rulesForPrompt } from "./settings.js";
import { currentTitle, refineTitle, titleOnFirstUserTurn } from "./titler.js";

const nowIso = () => new Date().toISOString();
const PERMISSION_TIMEOUT_MS = 120_000;
const IDLE_REAP_MS = Number(process.env.VIBE_CLAUDE_IDLE_MS ?? 30 * 60_000);

// Injectable so tests pass a fake. Shape matches the AI SDK streamText result we use.
type StreamTextFn = (args: any) => { fullStream: AsyncIterable<any>; response: Promise<{ messages: ModelMessage[] }> };
type ProviderFactory = (model: string) => any;

// Illustrative price floor (USD per 1M tokens), keyed by upstream model name. The
// registry (priceFor: models.json / OpenRouter) wins; unknown model → cost 0 (still
// reported). Keeps the meter roughly honest.
const PRICE_PER_M: Record<string, { in: number; out: number }> = {
  "gpt-4o": { in: 2.5, out: 10 },
  "gpt-4o-mini": { in: 0.15, out: 0.6 },
  "gpt-4.1": { in: 2, out: 8 },
  "gpt-4.1-mini": { in: 0.4, out: 1.6 },
};

// Default real provider (ADR 0016): resolve the session's model id to its native
// provider + upstream name. Keys are server-side env only (providers.ts).
function defaultProviderFactory(model: string): any {
  return nativeModel(providerFor(model), upstreamModel(model));
}

type HistoryRow = { role: string; content: string | null; tool_json: string | null };

const NOTE_INPUT_CHARS = 200;
const NOTE_RESULT_CHARS = 300;
const clip = (s: string, n: number) => (s.length > n ? s.slice(0, n) + "…" : s);

// One-line summary of a persisted tool call (ADR 0008 "summarize" resume).
export function toolNote(toolJson: string | null): string | null {
  let t: any;
  try {
    t = JSON.parse(toolJson ?? "");
  } catch {
    return null;
  }
  if (typeof t?.name !== "string") return null;
  const input = clip(JSON.stringify(t.input ?? {}), NOTE_INPUT_CHARS);
  const result = typeof t.result === "string" ? clip(t.result.replace(/\s+/g, " ").trim(), NOTE_RESULT_CHARS) : "(no result)";
  return `[tool ${t.name} ${input} → ${t.isError ? "error: " : ""}${result}]`;
}

// Rebuild the model conversation after a restart/evict (the live session keeps
// the SDK's real tool messages in memory). Tool rows can't be replayed as
// tool-call/tool-result pairs portably across providers, so each becomes a
// one-line note folded into the assistant turn it belongs to — the model keeps
// knowing which files it read or ran, at a few hundred chars per call. Notes
// never create a second assistant message in a row.
export function replayHistory(rows: HistoryRow[]): ModelMessage[] {
  const out: ModelMessage[] = [];
  let notes: string[] = [];
  const flush = () => {
    if (!notes.length) return;
    const text = notes.join("\n");
    notes = [];
    const last = out[out.length - 1];
    if (last?.role === "assistant" && typeof last.content === "string") last.content = `${last.content}\n${text}`;
    else out.push({ role: "assistant", content: text });
  };
  for (const r of rows) {
    if (r.role === "tool") {
      const n = toolNote(r.tool_json);
      if (n) notes.push(n);
    } else if (r.role === "assistant" && r.content != null) {
      const content = notes.length ? `${notes.join("\n")}\n${r.content}` : r.content;
      notes = [];
      const last = out[out.length - 1];
      if (last?.role === "assistant" && typeof last.content === "string") last.content = `${last.content}\n${content}`;
      else out.push({ role: "assistant", content });
    } else if (r.role === "user" && r.content != null) {
      flush();
      out.push({ role: "user", content: r.content });
    }
  }
  flush();
  return out;
}

export class NativeSession implements EngineSession {
  private ws: WebSocket | null = null;
  private stopped = false;
  private abort = new AbortController();
  private readonly gate: PermissionGate;
  private mode: SessionMode;
  private messages: ModelMessage[] = []; // committed conversation (resume = replay)
  private inbox: ModelMessage[] = []; // user turns awaiting a run (kept out of `messages` until their turn, so a concurrent pushUser can't reorder a generated reply)
  private running = false;
  private lastActivityMs = Date.now();
  // Running/phase/elapsed for the chat's status line (proposal 32).
  private readonly status = new TurnStatus((f) => this.send(f));
  private titlePrompt: string | null = null; // first turn, awaiting its LLM refine (ADR 0009)
  // Phone push when nobody is attached (ADR 0013). Replaceable in tests.
  notify: (type: PushType) => void = (type) => notifyDevices(this.db, type, this.id);

  constructor(
    private readonly db: DB,
    private readonly id: string,
    private readonly cwd: string,
    private readonly model: string,
    private readonly streamTextFn: StreamTextFn = realStreamText as unknown as StreamTextFn,
    private readonly providerFactory: ProviderFactory = defaultProviderFactory,
    private readonly permissionTimeoutMs = PERMISSION_TIMEOUT_MS,
    // Auto-titler's one-shot SDK call (ADR 0009); injectable for tests only —
    // production leaves it undefined so titler.ts uses the real Agent SDK.
    private readonly titleQueryFn?: any,
    // Persisted mode (proposal 25); 'plan' is meaningless here and treated as auto.
    initialMode: SessionMode = DEFAULT_MODE,
  ) {
    this.gate = new PermissionGate(this.db, this.id, (f) => this.send(f), this.permissionTimeoutMs, this.cwd, () => {
      if (!this.ws) this.notify("permission");
    });
    this.mode = initialMode === "ask" ? "ask" : "auto";
    this.gate.setAutoAllow(this.mode !== "ask");
    this.loadHistory();
  }

  // ---- lifecycle -----------------------------------------------------------

  // Native has no resumable server session — the transcript IS the state, already
  // loaded in the constructor. start() exists to satisfy EngineSession; any turn
  // primed before it (initial_prompt) has already been queued by pushUser.
  start(_resumeId?: string | null): void {
    void this.drain();
  }

  interrupt(): void {
    if (this.stopped) return;
    logEvent(this.db, "turn.interrupted", null, this.id);
    this.abort.abort();
    this.abort = new AbortController(); // fresh controller for the next turn
    this.send({ t: "result", subtype: "interrupt", cost: 0 });
  }

  stop(): void {
    this.stopped = true;
    this.abort.abort();
    this.gate.resolveAllDenied();
    this.status.end();
  }

  // ---- attach / detach -----------------------------------------------------

  attach(ws: WebSocket): void {
    this.ws = ws;
    // History replay — identical shape to ClaudeSession.attach (image refs surfaced
    // so the client lazy-fetches thumbnails via GET /attachments/:id).
    const { rows, omitted } = capHistory(
      this.db.prepare("SELECT role, content, tool_json, ts FROM messages WHERE session_id = ? ORDER BY ts").all(this.id) as any[],
    );
    const messages = rows.map((r) => {
      if (r.role === "user" && r.tool_json) {
        try {
          return { role: r.role, content: r.content, images: JSON.parse(r.tool_json).images, ts: r.ts };
        } catch {
          return r;
        }
      }
      return r;
    });
    this.sendTo(ws, { t: "history", messages, omitted });
    this.sendTo(ws, this.status.frame()); // a reattach learns whether a turn is still running (proposal 32)
    this.sendTo(ws, this.modeFrame());
    // Same reason as ClaudeSession.attach: a primed first turn titles before any
    // socket exists, so re-send whatever the row holds now (ADR 0009).
    const title = currentTitle(this.db, this.id);
    if (title) this.sendTo(ws, { t: "title", title });
    const cost =
      (this.db.prepare("SELECT total_cost_usd FROM sessions WHERE id = ?").get(this.id) as { total_cost_usd: number } | undefined)
        ?.total_cost_usd ?? 0;
    // Native init omits claudeSessionId (stateless); model + running cost for the meter.
    this.sendTo(ws, { t: "init", model: this.model, sessionCost: cost });
    this.gate.replay((f) => this.sendTo(ws, f));
  }

  detach(ws: WebSocket): void {
    if (this.ws === ws) this.ws = null; // a stale socket closing must not orphan the live one
  }

  isReapable(idleMs: number): boolean {
    return this.ws === null && !this.stopped && Date.now() - this.lastActivityMs > idleMs;
  }

  // ---- input / turns -------------------------------------------------------

  pushUser(text: string, imageIds: string[] = []): void {
    this.lastActivityMs = Date.now();
    const imgs = imageIds
      .map(
        (aid) =>
          this.db
            .prepare("SELECT id, media_type, data FROM attachments WHERE id = ? AND session_id = ?")
            .get(aid, this.id) as { id: string; media_type: string; data: Buffer } | undefined,
      )
      .filter((r): r is { id: string; media_type: string; data: Buffer } => !!r);

    const refs = imgs.map((i) => ({ id: i.id, mediaType: i.media_type }));
    this.insert("user", text, refs.length ? JSON.stringify({ images: refs }) : null);
    // Heuristic title now (first turn only), LLM refine once the turn resolves.
    this.titlePrompt = titleOnFirstUserTurn(this.db, this.id, this.cwd, text, (f) => this.send(f)) ?? this.titlePrompt;

    const content: any = imgs.length
      ? [
          ...(text ? [{ type: "text", text }] : []),
          ...imgs.map((i) => ({ type: "image", image: i.data, mediaType: i.media_type })),
        ]
      : text;
    this.inbox.push({ role: "user", content });
    void this.drain();
  }

  // Serialize turns: commit one queued user message into the conversation, run it to
  // completion (which appends the generated assistant/tool messages), then the next.
  // Queuing keeps a concurrent pushUser from interleaving a user message between a
  // turn's stream and its appended reply.
  private async drain(): Promise<void> {
    if (this.running || this.stopped) return;
    this.running = true;
    try {
      while (!this.stopped && this.model && this.inbox.length) {
        this.messages.push(this.inbox.shift()!);
        this.status.begin();
        await this.runTurn();
      }
    } finally {
      this.running = false;
      this.status.end();
    }
  }

  private async runTurn(): Promise<void> {
    const tools = buildNativeTools(this.gate, this.cwd, (f) => this.send(f));
    let model: any;
    try {
      model = this.providerFactory(this.model);
    } catch (e) {
      // Unconfigured provider (no key on the server): say so in the chat instead of
      // rejecting drain() — and drop the turn so the next one isn't stuck behind it.
      this.messages.pop();
      this.send({ t: "error", message: (e as Error)?.message ?? String(e) });
      this.send({ t: "result", subtype: "error", cost: 0 });
      return;
    }
    const result = this.streamTextFn({
      model,
      system:
        `You are a coding assistant operating in the project directory ${this.cwd} on the user's machine, reached from their phone. Be concise.` +
        (rulesForPrompt(this.db) ? `\n\n${rulesForPrompt(this.db)}` : ""),
      messages: this.messages,
      tools,
      // Chat = single step; with tools, allow a bounded agent loop.
      stopWhen: stepCountIs(tools ? 16 : 1),
      abortSignal: this.abort.signal,
    });

    let assistantText = "";
    try {
      for await (const part of result.fullStream as AsyncIterable<any>) {
        if (this.stopped) break;
        this.lastActivityMs = Date.now();
        this.status.touch();
        switch (part.type) {
          case "text-delta":
            this.status.set("writing");
            assistantText += part.text ?? "";
            if (part.text) this.send({ t: "delta", text: part.text });
            break;
          case "tool-call":
            this.status.set("tool", part.toolName ?? null);
            this.insert("tool", null, JSON.stringify({ id: part.toolCallId, name: part.toolName, input: part.input }));
            this.send({ t: "tool_use", id: part.toolCallId, name: part.toolName, input: part.input });
            break;
          case "tool-result": {
            const out = typeof part.output === "string" ? part.output : JSON.stringify(part.output ?? "");
            this.attachToolResult(part.toolCallId, out, false);
            this.send({ t: "tool_result", toolUseID: part.toolCallId, content: out, isError: false });
            this.status.set("thinking");
            break;
          }
          case "tool-error": {
            const out = String(part.error ?? "tool error");
            this.attachToolResult(part.toolCallId, out, true);
            this.send({ t: "tool_result", toolUseID: part.toolCallId, content: out, isError: true });
            this.status.set("thinking");
            break;
          }
          case "error":
            this.send({ t: "error", message: String(part.error ?? "error") });
            break;
          case "finish":
            // Settle the assistant bubble BEFORE the result frame (wire order:
            // deltas → assistant → result), then report cost.
            if (assistantText) {
              this.insert("assistant", assistantText, null);
              this.send({ t: "assistant", text: assistantText });
              assistantText = "";
            }
            this.reportCost(part.totalUsage);
            break;
        }
      }
    } catch (e) {
      if (!this.stopped) this.send({ t: "error", message: (e as Error)?.message ?? String(e) });
    }

    // Any assistant text not settled by a finish part (e.g. aborted mid-stream).
    if (assistantText) {
      this.insert("assistant", assistantText, null);
      this.send({ t: "assistant", text: assistantText });
    }
    // Append the model's generated messages (assistant + tool results) so the next
    // turn resumes with full native context.
    try {
      const gen = (await result.response)?.messages ?? [];
      this.messages.push(...(gen as ModelMessage[]));
    } catch {
      /* aborted — leave messages as-is */
    }
  }

  // Token usage → USD via the price map (unknown model → 0), accumulated into the
  // session total exactly like ClaudeSession, and reported on the result frame.
  private reportCost(usage: any): void {
    const price = priceFor(this.model) ?? PRICE_PER_M[upstreamModel(this.model)] ?? { in: 0, out: 0 };
    const inTok = usage?.inputTokens ?? usage?.promptTokens ?? 0;
    const outTok = usage?.outputTokens ?? usage?.completionTokens ?? 0;
    const cost = (inTok * price.in + outTok * price.out) / 1_000_000;
    recordUsage(this.db, {
      sessionId: this.id,
      provider: providerFor(this.model),
      model: this.model,
      input: inTok - (usage?.inputTokenDetails?.cacheReadTokens ?? usage?.cachedInputTokens ?? 0),
      output: outTok,
      cacheRead: usage?.inputTokenDetails?.cacheReadTokens ?? usage?.cachedInputTokens,
      cacheWrite: usage?.inputTokenDetails?.cacheWriteTokens,
      cost,
    });
    const total =
      (
        this.db
          .prepare("UPDATE sessions SET total_cost_usd = total_cost_usd + ? WHERE id = ? RETURNING total_cost_usd")
          .get(cost, this.id) as { total_cost_usd: number } | undefined
      )?.total_cost_usd ?? cost;
    this.insert("result", null, JSON.stringify({ subtype: "success", cost }));
    this.send({ t: "result", subtype: "success", cost, sessionCost: total });
    if (!this.ws) this.notify("done");
    this.flushTitleRefine();
  }

  // Upgrade the first turn's heuristic title with a one-shot model call (ADR 0009).
  // Fire-and-forget and consume-once. An interrupted first turn skips reportCost, so
  // the refine simply waits for the next completed turn — the heuristic already shows.
  private flushTitleRefine(): void {
    const prompt = this.titlePrompt;
    if (!prompt) return;
    this.titlePrompt = null;
    void refineTitle(this.db, this.id, this.cwd, prompt, (f) => this.send(f), this.titleQueryFn).catch(() => {});
  }

  // ---- permissions (delegate to the shared gate) ---------------------------

  onPermission(toolUseID: string, allow: boolean, deviceId: string | null = null): boolean {
    const ok = this.gate.onPermission(toolUseID, allow, deviceId);
    if (ok) this.status.resume();
    return ok;
  }

  setAutoAllow(on: boolean): void {
    this.setMode(on ? "auto" : "ask");
  }

  // Proposal 25: native has the gate but no SDK plan mode, so only ask/auto. The
  // chip hides Plan via `available` in the mode frame.
  setMode(mode: SessionMode, deviceId: string | null = null): boolean {
    if (this.stopped || mode === "plan" || mode === this.mode) return false;
    this.mode = mode;
    this.gate.setAutoAllow(mode !== "ask");
    this.db.prepare("UPDATE sessions SET mode = ? WHERE id = ?").run(mode, this.id);
    logEvent(this.db, "session.mode", deviceId, `${this.id}:${mode}`);
    this.send(this.modeFrame());
    return true;
  }

  private modeFrame(): Record<string, unknown> {
    return { t: "mode", mode: this.mode, available: ["ask", "auto"] };
  }

  // Native has no blocking dialogs (AskUserQuestion is Claude-only). No-op.
  onDialogResponse(_dialogId: string, _completed: boolean, _result: unknown): boolean {
    return false;
  }

  pending() {
    return { permissions: this.gate.pendingRequests(), dialogs: [] };
  }

  // ---- helpers (copied from claude.ts — 3-line writers, cheaper than a base class) ----

  private loadHistory(): void {
    const rows = this.db
      .prepare("SELECT role, content, tool_json FROM messages WHERE session_id = ? ORDER BY ts")
      .all(this.id) as HistoryRow[];
    this.messages.push(...replayHistory(rows));
  }

  private insert(role: string, content: string | null, toolJson: string | null): void {
    this.db
      .prepare("INSERT INTO messages (id, session_id, role, content, tool_json, ts) VALUES (?,?,?,?,?,?)")
      .run(randomUUID(), this.id, role, content, toolJson, nowIso());
  }

  private attachToolResult(toolUseId: string, content: string, isError: boolean): void {
    const row = this.db
      .prepare("SELECT id, tool_json FROM messages WHERE session_id = ? AND role = 'tool' AND tool_json LIKE ? ORDER BY ts DESC LIMIT 1")
      .get(this.id, `%"id":"${toolUseId}"%`) as { id: string; tool_json: string } | undefined;
    if (!row) return;
    let j: Record<string, unknown>;
    try {
      j = JSON.parse(row.tool_json);
    } catch {
      return;
    }
    j.result = content;
    j.isError = isError;
    this.db.prepare("UPDATE messages SET tool_json = ? WHERE id = ?").run(JSON.stringify(j), row.id);
  }

  private send(frame: Record<string, unknown>): void {
    // An approval card blocks the turn on the user (status line).
    if (frame.t === "permission_request") this.status.wait();
    if (this.ws) this.sendTo(this.ws, frame);
  }

  private sendTo(ws: WebSocket, frame: Record<string, unknown>): void {
    if (ws.readyState === ws.OPEN) ws.send(JSON.stringify(frame));
  }
}

export const NATIVE_IDLE_REAP_MS = IDLE_REAP_MS;
export { nativeTier };
