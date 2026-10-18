// Claude session manager (M3, protocols/claude-ws.md). Drives the Agent SDK
// (@anthropic-ai/claude-agent-sdk) headless and bridges it to a JSON WebSocket.
//
// Durability: unlike a tmux terminal, a Claude session is an in-process SDK
// subprocess. It lives in an in-daemon registry decoupled from the WS — a phone
// drop DETACHES (the query loop keeps running); reconnect re-attaches and replays
// the transcript from SQLite. Across a daemon restart the loop is gone but the
// next attach resumes via `options.resume = claude_session_id` (the SDK persists
// to ~/.claude/projects; we keep our own copy in `messages`).
//
// Permissions (security.md): permissionMode 'default' + canUseTool. Auto-allow
// is ON by default (every decision audited as permission.auto_allow); a client
// `auto_allow` frame toggles it per session. With auto-allow off, canUseTool
// round-trips every tool call to the phone; deny on timeout (no client attached
// → a push goes out, ADR 0013). AskUserQuestion always round-trips and never
// times out.
// `queryFn` is injectable so tests run a fake generator — no real subprocess.

import { randomUUID } from "node:crypto";
import { query as sdkQuery } from "@anthropic-ai/claude-agent-sdk";
import type { WebSocket } from "ws";
import type { DB } from "./db.js";
import { logEvent } from "./auth.js";
import { gatewayEnv, isNativeProvider, providerFor } from "./gateway.js";
import { rulesForPrompt } from "./settings.js";
import { compactNotice, summarizeContext, type ContextFrame } from "./context.js";
import { publicCommands, skillNamesFrom, type CommandInfo } from "./commands.js";
import { parseMcpAction, summarizeMcp } from "./mcp.js";
import { getUsage, ingestRateLimit } from "./usage.js";
import { cumulativeCostDelta, recordCumulative } from "./spend.js";
import { capHistory } from "./history.js";
import { autoScopeDirs, fileToolInScope } from "./file-scope.js";
import { PermissionGate } from "./permission-gate.js";
import { toolResultImages } from "./attachments.js";
import { notifyDevices, type PushType } from "./push.js";
import { leasedToolPath, leaseBlocker } from "./tasks.js";
import { currentTitle, refineTitle, titleOnFirstUserTurn } from "./titler.js";
import { DEFAULT_MODE, SESSION_MODES, type EngineSession, type RewindResult, type SessionMode } from "./engine.js";
import { TurnStatus } from "./turn-status.js";
import { createPeerServer, PEER_SERVER } from "./peer-tools.js";

// Loose SDK shapes — the SDK's types are large; the spike already casts (any).
type SdkMsg = any;
type QueryFn = (params: { prompt: AsyncIterable<any>; options: any }) => AsyncGenerator<SdkMsg> & {
  interrupt?: () => Promise<void>;
};

const nowIso = () => new Date().toISOString();

// A tool_result block's content is a string or an array of content blocks
// (proposal 07). Flatten to plain text for the chat.
function toolResultText(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content.map((c) => (typeof c === "string" ? c : ((c as { text?: string })?.text ?? ""))).join("");
  }
  return "";
}
// Show the model's thinking (summarized). The SDK default is `omitted`: the block
// still arrives but empty, so nothing could be shown (M9 spike). Set
// VIBE_SHOW_THINKING=0 to keep the old behaviour. Read per session start.
const showThinking = (): boolean => !/^(0|false|off|no)$/i.test(process.env.VIBE_SHOW_THINKING ?? "");
// An SDK message's `content` is normally an array of blocks, but synthetic ones are a
// plain string — e.g. the "Set model to …" echo that Query.setModel() produces as a
// `user` message. Treat anything that isn't an array as "no blocks"; calling .filter on
// a string used to throw out of the consume loop and kill the whole session.
const contentBlocks = (content: unknown): any[] => (Array.isArray(content) ? content : []);
// Reasoning effort levels the SDK accepts (EffortLevel). A model without effort support
// downgrades or ignores it silently — the SDK decides, not us.
export const EFFORT_LEVELS = ["low", "medium", "high", "xhigh", "max"] as const;
export type EffortLevel = (typeof EFFORT_LEVELS)[number];
const parseEffort = (x: unknown): EffortLevel | null =>
  typeof x === "string" && (EFFORT_LEVELS as readonly string[]).includes(x) ? (x as EffortLevel) : null;

const PERMISSION_TIMEOUT_MS = 120_000; // 2 min → deny
// Detached + quiet past this → the reaper evicts the SDK subprocess (RAM). The
// next attach resumes from claude_session_id, so eviction is invisible to the user.
const IDLE_REAP_MS = Number(process.env.VIBE_CLAUDE_IDLE_MS ?? 30 * 60_000);
const REAP_INTERVAL_MS = 60_000;

// deviceId = the device that answered (set by onDialogResponse; only the exit_plan
// resolver uses it, to attribute the mode switch it triggers).
type Pending = { resolve: (r: unknown, deviceId?: string | null) => void; req: Record<string, unknown> };

// App mode → SDK permissionMode (proposal 25). 'ask' and 'auto' differ only in the
// gate's auto-allow flag; both run the SDK in 'default'.
const sdkMode = (m: SessionMode): "default" | "plan" => (m === "plan" ? "plan" : "default");

export class ClaudeSession implements EngineSession {
  // Every attached client (phone + desktop) gets every frame; first answer wins.
  private readonly sockets = new Set<WebSocket>();
  private queue: any[] = [];
  private wake: (() => void) | null = null;
  private inputClosed = false;
  private stopped = false;
  private abort = new AbortController();
  // For per-turn interrupt (proposal 09) and live mode switching (proposal 25).
  private query: {
    interrupt?: () => Promise<void>;
    setPermissionMode?: (m: string) => Promise<void>;
    setModel?: (model?: string) => Promise<void>;
    applyFlagSettings?: (settings: Record<string, unknown>) => Promise<void>;
    getContextUsage?: (o?: { detail?: "summary" | "full" }) => Promise<unknown>;
    supportedCommands?: () => Promise<unknown>;
    mcpServerStatus?: () => Promise<unknown>;
    reconnectMcpServer?: (name: string) => Promise<void>;
    toggleMcpServer?: (name: string, enabled: boolean) => Promise<void>;
    rewindFiles?: (userMessageId: string, o?: { dryRun?: boolean }) => Promise<RewindResult>;
  } | null = null;
  private mode: SessionMode;
  private effort: EffortLevel | null = null; // null = the model's default
  private lastContext: ContextFrame | null = null; // newest context-window reading (proposal 40)
  private rulesApplied: string[] | null = null; // rule names THIS session started with (ADR 0026/0031); null = none
  private commands: CommandInfo[] | null = null; // skills / slash commands (proposal 41)
  // Set by session-ws.ts when the session is created: enables the session-to-session
  // tools (peer-tools.ts, proposal 30). Null (tests, spikes) → no peer tools.
  peerRegistry: Map<string, EngineSession> | null = null;
  private prePlanMode: SessionMode = DEFAULT_MODE; // where an approved plan returns to
  // Tool-permission round-trips run through the shared gate (permission-gate.ts,
  // ADR 0008). AskUserQuestion / other dialogs stay here (Claude-specific).
  private readonly gate: PermissionGate;
  private pendingDialogs = new Map<string, Pending>();
  private lastActivityMs = Date.now(); // touched by SDK traffic + user input (reaper input)
  // Running/phase/elapsed for the chat's status line (proposal 32).
  private readonly status = new TurnStatus((f) => this.send(f));
  private titlePrompt: string | null = null; // first turn, awaiting its LLM refine (ADR 0009)
  claudeSessionId: string | null = null;
  // Phone push when nobody is attached (ADR 0013). Replaceable in tests.
  notify: (type: PushType) => void = (type) => notifyDevices(this.db, type, this.id);

  constructor(
    private readonly db: DB,
    private readonly id: string, // our session id
    private readonly cwd: string,
    private readonly queryFn: QueryFn = sdkQuery as unknown as QueryFn,
    private readonly permissionTimeoutMs = PERMISSION_TIMEOUT_MS,
    // Per-session upstream model id (ADR 0007). null/undefined = gateway/CLI default.
    private model: string | null = null,
    // Persisted mode (sessions.mode, proposal 25) so a reaped/resumed session
    // never silently falls back from plan/ask to auto-allow.
    initialMode: SessionMode = DEFAULT_MODE,
  ) {
    this.gate = new PermissionGate(
      this.db,
      this.id,
      (f) => this.send(f),
      this.permissionTimeoutMs,
      this.cwd,
      () => {
        if (this.sockets.size === 0) this.notify("permission");
      },
      // Auto mode never touches files outside the project folders silently (security.md #7).
      (tool, input) => fileToolInScope(tool, input, this.cwd, autoScopeDirs(this.db, this.cwd)),
    );
    this.mode = initialMode;
    this.gate.setAutoAllow(initialMode !== "ask");
    // Persisted effort (proposal 39): a resumed or restarted session keeps its level.
    // Read here, not in start(), so attach() reports it whichever runs first.
    this.effort = parseEffort((this.db.prepare("SELECT effort FROM sessions WHERE id = ?").get(this.id) as { effort: string | null } | undefined)?.effort);
  }

  // ---- lifecycle -----------------------------------------------------------

  start(resumeId?: string | null): void {
    // Daemon-wide session rules (ADR 0026) ride on the Claude Code preset, so the
    // project's own CLAUDE.md still loads alongside them (M10 spike). Read at every
    // (re)start: a change applies to sessions started after it.
    const rules = rulesForPrompt(this.db, (this.db.prepare("SELECT project_id FROM sessions WHERE id = ?").get(this.id) as { project_id: string | null } | undefined)?.project_id ?? null);
    this.rulesApplied = rules?.names ?? null;
    const q = this.queryFn({
      prompt: this.input(),
      options: {
        cwd: this.cwd,
        includePartialMessages: true,
        permissionMode: sdkMode(this.mode),
        // Back up files before edits so rewind() can restore them (ADR 0023).
        enableFileCheckpointing: true,
        effort: this.effort ?? undefined,
        systemPrompt: rules ? { type: "preset", preset: "claude_code", append: rules.text } : undefined,
        thinking: showThinking() ? { type: "adaptive", display: "summarized" } : undefined,
        canUseTool: this.canUseTool,
        onUserDialog: this.onUserDialog,
        resume: resumeId ?? undefined,
        abortController: this.abort,
        // Model-agnostic (ADR 0007): pick the upstream model, and — when a gateway
        // is configured — point the SDK subprocess at it. Both are no-ops by
        // default (undefined model → CLI default; undefined env → inherit
        // process.env, i.e. real Claude via CLI login).
        model: this.model ?? undefined,
        env: gatewayEnv(),
        mcpServers: this.peerRegistry
          ? {
              [PEER_SERVER]: createPeerServer({
                db: this.db,
                registry: this.peerRegistry,
                selfId: this.id,
                getMode: () => this.mode,
              }),
            }
          : undefined,
      },
    });
    this.query = q;
    // The real SDK answers this before any user message (625 ms, M13 spike) — and only emits
    // `init` once the first message is sent, so waiting for init would leave the composer's
    // "/" list empty in a fresh session.
    this.loadCommands();
    void this.consume(q);
  }

  // Cancel the in-flight turn without ending the session (proposal 09). The SDK
  // finalizes with a result subtype 'interrupt'; the input queue stays intact for
  // the next turn (distinct from stop(), which aborts the whole loop).
  interrupt(): void {
    if (this.stopped) return;
    logEvent(this.db, "turn.interrupted", null, this.id);
    void this.query?.interrupt?.();
  }

  // ---- MCP servers (proposal 43) --------------------------------------------------

  // On demand only (the tool lists can be big): the client asks with `get_mcp`.
  sendMcpStatus(to?: WebSocket): void {
    const q = this.query;
    if (!q?.mcpServerStatus || this.stopped) return;
    void q
      .mcpServerStatus()
      .then((raw) => {
        const frame = { t: "mcp", ...summarizeMcp(raw) };
        if (to) this.sendTo(to, frame);
        else this.send(frame);
      })
      .catch(() => {});
  }

  // reconnect | enable | disable one server of THIS session. The name must be one the SDK
  // itself lists — a client-supplied string is never passed on unchecked. Audited.
  async mcpAction(server: string, action: string, deviceId: string | null = null): Promise<boolean> {
    const act = parseMcpAction(action);
    const q = this.query;
    if (this.stopped || !act || typeof server !== "string" || !q?.mcpServerStatus) return false;
    let known = false;
    let ok = false;
    try {
      known = summarizeMcp(await q.mcpServerStatus()).servers.some((s) => s.name === server);
      if (known) {
        if (act === "reconnect") await q.reconnectMcpServer?.(server);
        else await q.toggleMcpServer?.(server, act === "enable");
        ok = true;
      }
    } catch {
      /* the SDK rejects when a server it just (re)started still fails to come up — the
         action was carried out; the refreshed status below shows the real state */
    } finally {
      this.sendMcpStatus(); // always show the truth afterwards
    }
    // Audit every permitted attempt with its outcome (not just the clean ones).
    if (known) logEvent(this.db, "session.mcp", deviceId, `${this.id}:${act}:${server.slice(0, 80)}:${ok ? "ok" : "failed"}`);
    return ok;
  }

  // ---- slash commands / skills (proposal 41) --------------------------------------

  private commandsFrame(): Record<string, unknown> {
    return { t: "commands", commands: this.commands ?? [] };
  }

  private skillNames: Set<string> = new Set(); // which built-in rows are skills (see commands.ts)
  private commandsLoading = false; // a read is in flight (init can arrive before it finishes)

  private setCommands(raw: unknown): void {
    const next = publicCommands(raw, this.skillNames);
    if (this.commands && JSON.stringify(next) === JSON.stringify(this.commands)) return; // nothing changed
    this.commands = next;
    this.send(this.commandsFrame());
  }

  // Best-effort (the list is a convenience): fetched once per start, then kept fresh by the
  // SDK's own commands_changed message.
  private loadCommands(): void {
    const q = this.query;
    if (!q?.supportedCommands || this.stopped || this.commandsLoading) return;
    this.commandsLoading = true;
    // The context response tells skills (offered) from terminal built-ins (withheld).
    const skills = (q.getContextUsage?.({ detail: "summary" }) ?? Promise.resolve(null)).then(skillNamesFrom, () => new Set<string>());
    void Promise.all([q.supportedCommands(), skills])
      .then(([raw, names]) => {
        this.skillNames = names;
        this.setCommands(raw);
      })
      .catch(() => {})
      .finally(() => {
        this.commandsLoading = false;
      });
  }

  // ---- context window (proposal 40) ---------------------------------------------

  // `rules`: whether the daemon's session rules were appended when this session started.
  private contextFrame(c: ContextFrame): Record<string, unknown> {
    return { t: "context", ...c, rules: this.rulesApplied !== null, ruleNames: this.rulesApplied ?? [] };
  }

  // Read the window usage (summary: ~20 ms, no per-category token-count calls) and send it
  // to everyone attached, or just to [to]. Best-effort: telemetry must never break a turn.
  private emitContext(to?: WebSocket): void {
    const q = this.query;
    if (!q?.getContextUsage || this.stopped) return;
    void q
      .getContextUsage({ detail: "summary" })
      .then((raw) => {
        const c = summarizeContext(raw);
        if (!c) return;
        this.lastContext = c;
        const frame = this.contextFrame(c);
        if (to) this.sendTo(to, frame);
        else this.send(frame);
      })
      .catch(() => {});
  }

  // Compact the conversation now (client `compact` frame). The SDK treats a streamed
  // "/compact" as the slash command (M12 spike): it summarizes older turns, emits a
  // compact_boundary and a result. Refused while a turn runs or before the engine started.
  // Not stored as a user message — it is a command, not something the user said.
  compact(deviceId: string | null = null): boolean {
    if (this.stopped || !this.query || this.status.running) return false;
    logEvent(this.db, "session.compact", deviceId, this.id);
    this.lastActivityMs = Date.now();
    this.status.begin();
    this.queue.push({ type: "user", message: { role: "user", content: "/compact" }, parent_tool_use_id: null });
    this.wake?.();
    this.wake = null;
    return true;
  }

  // ---- file rewind (ADR 0023) ------------------------------------------------

  busy(): boolean {
    return this.status.running;
  }

  // Thin wrapper: all validation (capability, dry-run, root check, audit) lives in
  // checkpoints.ts. A missing/failed query surfaces as canRewind:false, not a throw.
  async rewind(sdkUuid: string, dryRun: boolean): Promise<RewindResult> {
    if (!this.query?.rewindFiles) return { canRewind: false, error: "rewind unavailable" };
    try {
      return await this.query.rewindFiles(sdkUuid, { dryRun });
    } catch (e) {
      return { canRewind: false, error: (e as Error)?.message ?? String(e) };
    }
  }

  announceRewound(messageId: string, files: string[]): void {
    this.send({ t: "rewound", messageId, filesChanged: files, ts: nowIso() });
  }

  // `code` is what attached clients see: 1012 → they reconnect and resume via
  // getOrStart; 4404 → they stop (session deleted or worktree missing).
  stop(code = 1012, reason = "session stopped"): void {
    this.stopped = true;
    this.inputClosed = true;
    this.wake?.();
    this.abort.abort();
    this.gate.resolveAllDenied();
    for (const [, p] of this.pendingDialogs) p.resolve({ behavior: "cancelled" });
    this.pendingDialogs.clear();
    this.status.end();
    for (const ws of this.sockets) ws.close(code, reason);
    this.sockets.clear();
  }

  // ---- client attach / detach ---------------------------------------------

  attach(ws: WebSocket): void {
    this.sockets.add(ws);
    const all = this.db
      .prepare("SELECT id, role, content, tool_json, ts FROM messages WHERE session_id = ? ORDER BY ts")
      .all(this.id) as any[];
    const { rows, omitted } = capHistory(all); // history.ts: a 35 MB replay crashed the phone
    // A user row's tool_json carries its image refs; surface them as `images` so
    // the client lazy-fetches each via GET /attachments/:id (claude-ws.md).
    const messages = rows.map((r) => {
      if (r.role === "user" && r.tool_json) {
        try {
          return { id: r.id, role: r.role, content: r.content, images: JSON.parse(r.tool_json).images, ts: r.ts };
        } catch {
          return r;
        }
      }
      return r;
    });
    this.sendTo(ws, { t: "history", messages, omitted });
    this.sendTo(ws, this.status.frame()); // a reattach learns whether a turn is still running (proposal 32)
    this.sendTo(ws, this.modeFrame()); // daemon is the source of truth for the mode chip
    this.sendTo(ws, this.modelFrame());
    this.sendTo(ws, this.effortFrame());
    if (this.commands) this.sendTo(ws, this.commandsFrame());
    // Context meter (proposal 40): the last reading right away, a fresh one if idle.
    if (this.lastContext) this.sendTo(ws, this.contextFrame(this.lastContext));
    if (!this.status.running) this.emitContext(ws);
    // A create-with-prompt session (proposal 15) is primed BEFORE attach, so its
    // heuristic title frame went nowhere — re-send whatever the row holds now.
    const title = currentTitle(this.db, this.id);
    if (title) this.sendTo(ws, { t: "title", title });
    if (this.claudeSessionId) {
      this.sendTo(ws, { t: "init", claudeSessionId: this.claudeSessionId });
      // Surface the real Max-plan meters on reattach (best-effort, fail-soft).
      this.emitUsage(ws);
    }
    this.gate.replay((f) => this.sendTo(ws, f)); // replay pending approvals
    for (const { req } of this.pendingDialogs.values()) this.sendTo(ws, req); // replay pending dialogs
  }

  detach(ws: WebSocket): void {
    this.sockets.delete(ws);
  }

  // Detached and quiet past `idleMs` → safe to evict (frees the SDK subprocess;
  // reattach resumes via claude_session_id). handle() touches lastActivityMs on
  // every SDK message even while detached, so an in-progress turn is never reaped.
  isReapable(idleMs: number): boolean {
    return this.sockets.size === 0 && !this.stopped && Date.now() - this.lastActivityMs > idleMs;
  }

  // ---- input (multi-turn) --------------------------------------------------

  // attachmentIds reference rows uploaded via POST /sessions/:id/attachments
  // (attachments.ts). Each must belong to THIS session (the session_id filter is
  // the ownership gate — a turn can't pull another session's image). With images
  // the SDK content becomes an array of text + image blocks (spike-image.ts: the
  // SDK forwards {type:'image', source:{base64}} in the input stream).
  pushUser(text: string, attachmentIds: string[] = [], from?: WebSocket): void {
    if (this.stopped) return; // a frame still in flight as stop() closed the socket
    this.lastActivityMs = Date.now();
    const imgs = attachmentIds
      .map(
        (aid) =>
          this.db
            .prepare("SELECT id, media_type, data FROM attachments WHERE id = ? AND session_id = ?")
            .get(aid, this.id) as { id: string; media_type: string; data: Buffer } | undefined,
      )
      .filter((r): r is { id: string; media_type: string; data: Buffer } => !!r);

    const refs = imgs.map((i) => ({ id: i.id, mediaType: i.media_type }));
    // The uuid goes on the SDK message AND in the row: rewindFiles() needs it and
    // nothing echoes it back (ADR 0023, M8 spike).
    const sdkUuid = randomUUID();
    const messageId = this.insert("user", text, refs.length ? JSON.stringify({ images: refs }) : null, sdkUuid);
    // The sender added this bubble locally; tell it the row id so it can offer
    // "rewind files to here" without a reattach (claude-ws.md `user_ack`).
    // Every other attached device gets the turn itself (proposal 58).
    const turn = { t: "user_turn", text, messageId, images: refs.map((r) => r.id), ts: nowIso() };
    for (const ws of this.sockets) this.sendTo(ws, ws === from ? { t: "user_ack", messageId } : turn);
    this.status.begin();
    // Heuristic title now (first turn only), LLM refine after the turn resolves.
    this.titlePrompt = titleOnFirstUserTurn(this.db, this.id, this.cwd, text, (f) => this.send(f)) ?? this.titlePrompt;

    const content = imgs.length
      ? [
          ...(text ? [{ type: "text", text }] : []),
          ...imgs.map((i) => ({
            type: "image",
            source: { type: "base64", media_type: i.media_type, data: i.data.toString("base64") },
          })),
        ]
      : text;
    this.queue.push({ type: "user", message: { role: "user", content }, parent_tool_use_id: null, uuid: sdkUuid });
    this.wake?.();
    this.wake = null;
  }

  private async *input(): AsyncGenerator<any> {
    while (!this.inputClosed) {
      while (this.queue.length) yield this.queue.shift();
      if (this.inputClosed) break;
      await new Promise<void>((res) => (this.wake = res));
    }
  }

  // ---- permission round-trip ----------------------------------------------

  // Legacy toggle (client `auto_allow` frame, proposal 18) — kept for old clients and
  // tests. Maps onto ask/auto; it never leaves plan (a stale client can't talk a
  // planning session into executing).
  setAutoAllow(on: boolean): void {
    if (this.mode === "plan") return;
    this.setMode(on ? "auto" : "ask");
  }

  private modeFrame(): Record<string, unknown> {
    return { t: "mode", mode: this.mode, available: [...SESSION_MODES] };
  }

  // The session's current model + that it can be switched live (Claude engine only —
  // the native engine sends no such frame, so the app hides the action there).
  private modelFrame(): Record<string, unknown> {
    return { t: "model", model: this.model, canSwitch: true };
  }

  private effortFrame(): Record<string, unknown> {
    return { t: "effort", effort: this.effort, levels: [...EFFORT_LEVELS] };
  }

  // Change reasoning effort mid-session (client `set_effort` frame, proposal 39). `null`
  // returns to the model's default. Query.applyFlagSettings({effortLevel}) applies it to the
  // next turn; the level is persisted so a resume/restart keeps it.
  async setEffort(level: string | null, deviceId: string | null = null): Promise<boolean> {
    if (this.stopped) return false;
    const next = level === null ? null : parseEffort(level);
    if (level !== null && next === null) return false; // not a whitelisted level
    if (next === this.effort) return false;
    try {
      await this.query?.applyFlagSettings?.({ effortLevel: next });
    } catch {
      return false; // the SDK refused it — nothing changed
    }
    this.effort = next;
    this.db.prepare("UPDATE sessions SET effort = ? WHERE id = ?").run(next, this.id);
    logEvent(this.db, "session.effort", deviceId, `${this.id}:${next ?? "default"}`);
    this.send(this.effortFrame());
    return true;
  }

  // Switch model mid-session (client `set_model` frame). Claude-engine models only:
  // a native provider (openai:/google:/…) is a different engine, so crossing to one
  // would need a new session (the hand-off flow). SDK: Query.setModel changes the
  // model for subsequent responses; conversation context carries over.
  async setModel(model: string, deviceId: string | null = null): Promise<boolean> {
    if (this.stopped || typeof model !== "string") return false;
    const m = model.trim();
    if (!m || m.length > 128 || /[\s\u0000-\u001f]/.test(m) || m === this.model) return false;
    if (isNativeProvider(providerFor(m))) return false;
    try {
      await this.query?.setModel?.(m);
    } catch {
      return false; // the SDK refused it (unknown to the gateway/CLI) — nothing changed
    }
    this.model = m;
    this.db.prepare("UPDATE sessions SET model = ? WHERE id = ?").run(m, this.id);
    logEvent(this.db, "session.model", deviceId, `${this.id}:${m}`);
    this.send(this.modelFrame());
    return true;
  }

  // Switch mode (client `mode` frame, proposal 25). The gate flag flips locally; the
  // SDK is told live via Query.setPermissionMode (spike: works over streaming input;
  // before start() the mode is applied through options.permissionMode instead).
  // Turning auto-allow on flushes any request already waiting on the phone (gate).
  setMode(mode: SessionMode, deviceId: string | null = null): boolean {
    if (this.stopped || mode === this.mode) return false;
    if (mode === "plan") this.prePlanMode = this.mode;
    this.mode = mode;
    this.gate.setAutoAllow(mode !== "ask");
    this.db.prepare("UPDATE sessions SET mode = ? WHERE id = ?").run(mode, this.id);
    logEvent(this.db, "session.mode", deviceId, `${this.id}:${mode}`);
    void this.query?.setPermissionMode?.(sdkMode(mode)).catch(() => {});
    this.send(this.modeFrame());
    return true;
  }

  // canUseTool fires when the model wants a tool. AskUserQuestion is Claude-specific
  // (Q&A, not a permission) and handled here; every other tool goes through the
  // shared permission gate (permission-gate.ts), same as the native engine.
  private canUseTool = (toolName: string, input: Record<string, unknown>, opts: any): Promise<unknown> => {
    // AskUserQuestion is NOT a user_dialog in SDK 0.3.169 — it arrives through
    // canUseTool. Render its questions on the phone and return the picks via
    // updatedInput.answers (the tool's "answers collected by the permission
    // component" contract), not a generic allow/deny card. See claude-ws.md.
    if (toolName === "AskUserQuestion") return this.askUserQuestion(input, opts?.toolUseID);
    // ExitPlanMode is the plan's approval step (proposal 25): it must reach the
    // phone even with auto-allow on, or a plan would approve itself.
    if (toolName === "ExitPlanMode") return this.exitPlan(input, opts?.toolUseID);
    // File leases (proposal 65): another session's running|review task covering this
    // path denies the write. Advisory, Bash is not checked; before the gate so a lease
    // never costs a phone approval.
    const rel = leasedToolPath(toolName, input, this.cwd);
    const lease = rel ? leaseBlocker(this.db, this.id, rel) : null;
    if (rel && lease) {
      logEvent(this.db, "lease.deny", null, `${this.id}:${rel}`);
      return Promise.resolve({
        behavior: "deny",
        message: `${rel} is leased by task '${lease.title}' (session ${lease.session_id ?? "starting"}). Pick other files, or ask that session with send_message.`,
      });
    }
    // allow MUST echo updatedInput (SDK runtime schema — the gate returns it).
    return this.gate.request(toolName, input, opts);
  };

  // AskUserQuestion round-trip. Reuses the user_dialog frame + the phone's
  // question UI, but resolves the canUseTool promise: completed → allow with the
  // answers folded into updatedInput; cancel → allow with the original input
  // (the tool then reports "user did not answer"). No timeout — the question
  // waits indefinitely for the user (replayed on reattach, pushed to the phone
  // if nobody is attached — ADR 0013; a session stop() resolves it as cancelled).
  private askUserQuestion = (input: Record<string, unknown>, toolUseID?: string): Promise<unknown> => {
    const dialogId = randomUUID();
    const req = { t: "user_dialog", dialogId, dialogKind: "ask_user_question", payload: input, toolUseID };
    return new Promise((resolve) => {
      const done = (r: any) => {
        this.pendingDialogs.delete(dialogId);
        const answers = r?.behavior === "completed" ? ((r.result as any)?.answers ?? {}) : undefined;
        resolve({ behavior: "allow", updatedInput: answers ? { ...input, answers } : input });
      };
      this.pendingDialogs.set(dialogId, { resolve: done, req });
      this.send(req);
      if (this.sockets.size === 0) this.notify("question");
    });
  };

  // ExitPlanMode round-trip (proposal 25). Same shape as askUserQuestion: a
  // user_dialog the phone renders as a plan card, no timeout, replayed on reattach,
  // pushed when detached. Result `{approve, mode?, feedback?}`:
  //  - approve → allow (the SDK itself leaves plan mode — spike), then move to the
  //    chosen mode ('auto'|'ask', default: where the session was before plan);
  //  - reject  → deny with the user's feedback so the model keeps planning;
  //  - cancelled (session stop) → deny.
  private exitPlan = (input: Record<string, unknown>, toolUseID?: string): Promise<unknown> => {
    const dialogId = randomUUID();
    const payload = { plan: input.plan, planFilePath: input.planFilePath };
    const req = { t: "user_dialog", dialogId, dialogKind: "exit_plan", payload, toolUseID };
    return new Promise((resolve) => {
      const done = (r: any, deviceId: string | null = null) => {
        this.pendingDialogs.delete(dialogId);
        const res = r?.behavior === "completed" ? ((r.result ?? {}) as any) : null;
        if (!res?.approve) {
          const fb = typeof res?.feedback === "string" && res.feedback.trim() ? res.feedback.trim() : null;
          resolve({ behavior: "deny", message: fb ?? "The user wants to keep planning." });
          return;
        }
        resolve({ behavior: "allow", updatedInput: input });
        // Only if still in plan: the user may have switched modes by hand meanwhile.
        if (this.mode === "plan") {
          const picked = res.mode === "ask" || res.mode === "auto" ? (res.mode as SessionMode) : this.prePlanMode;
          this.setMode(picked, deviceId);
        }
      };
      this.pendingDialogs.set(dialogId, { resolve: done, req });
      this.send(req);
      if (this.sockets.size === 0) this.notify("question");
    });
  };

  onPermission(toolUseID: string, allow: boolean, deviceId: string | null = null): boolean {
    const ok = this.gate.onPermission(toolUseID, allow, deviceId);
    if (ok) this.status.resume();
    return ok;
  }

  pending() {
    return { permissions: this.gate.pendingRequests(), dialogs: [...this.pendingDialogs.values()].map((p) => p.req) };
  }

  // ---- user-dialog round-trip (AskUserQuestion etc.) -----------------------

  // onUserDialog fires when the CLI asks the host to render a blocking dialog
  // (the AskUserQuestion tool routes here, NOT through canUseTool). We forward
  // the dialog opaquely to the phone and block until it answers. Unknown dialog
  // kinds are the client's problem to recognize; we just transport. Cancel (the
  // dialog contract's "apply default") on timeout or if no client is attached.
  private onUserDialog = (
    request: { dialogKind: string; payload: Record<string, unknown>; toolUseID?: string },
  ): Promise<unknown> => {
    if (this.sockets.size === 0) return Promise.resolve({ behavior: "cancelled" });
    const dialogId = randomUUID();
    const req = {
      t: "user_dialog",
      dialogId,
      dialogKind: request.dialogKind,
      payload: request.payload,
      toolUseID: request.toolUseID,
    };
    return new Promise((resolve) => {
      this.pendingDialogs.set(dialogId, { resolve, req });
      this.send(req);
      setTimeout(() => {
        if (this.pendingDialogs.delete(dialogId)) {
          logEvent(this.db, "dialog.timeout", null, `${this.id}:${request.dialogKind}`);
          this.send({ t: "dialog_closed", dialogId });
          resolve({ behavior: "cancelled" });
        }
      }, this.permissionTimeoutMs);
    });
  };

  onDialogResponse(dialogId: string, completed: boolean, result: unknown, deviceId: string | null = null): boolean {
    const p = this.pendingDialogs.get(dialogId);
    if (!p) return false;
    this.pendingDialogs.delete(dialogId);
    this.send({ t: "dialog_closed", dialogId }); // first answer wins; other devices drop the card
    logEvent(this.db, completed ? "dialog.completed" : "dialog.cancelled", deviceId, `${this.id}:${p.req.dialogKind as string}`);
    p.resolve(completed ? { behavior: "completed", result } : { behavior: "cancelled" }, deviceId);
    this.status.resume();
    return true;
  }

  // ---- SDK event loop ------------------------------------------------------

  private async consume(q: AsyncGenerator<SdkMsg>): Promise<void> {
    try {
      for await (const msg of q) {
        if (this.stopped) break;
        this.handle(msg);
      }
    } catch (e) {
      if (!this.stopped) this.send({ t: "error", message: (e as Error)?.message ?? String(e) });
    }
    this.status.end(); // the loop is over — no turn can still be running
  }

  private handle(msg: SdkMsg): void {
    this.lastActivityMs = Date.now(); // fires even while detached → in-progress turns survive the reaper
    this.status.touch();
    switch (msg.type) {
      case "system":
        if (msg.subtype === "init") {
          this.claudeSessionId = msg.session_id;
          this.db.prepare("UPDATE sessions SET claude_session_id = ? WHERE id = ?").run(msg.session_id, this.id);
          this.send({ t: "init", claudeSessionId: msg.session_id, model: msg.model });
          if (!this.commands) this.loadCommands(); // retry if the startup read failed
        } else if (msg.subtype === "commands_changed") {
          this.setCommands(msg.commands); // a skill/plugin appeared or went away
        } else if (msg.subtype === "compact_boundary") {
          // Manual (/compact) or automatic: keep a visible, replayable record of it.
          const text = compactNotice(msg.compact_metadata);
          this.insert("notice", text, null);
          this.send({
            t: "compacted",
            text,
            trigger: msg.compact_metadata?.trigger === "auto" ? "auto" : "manual",
            preTokens: msg.compact_metadata?.pre_tokens ?? null,
            postTokens: msg.compact_metadata?.post_tokens ?? null,
          });
        }
        break;
      case "rate_limit_event":
        ingestRateLimit(msg.rate_limit_info);
        break;
      case "stream_event": {
        const ev = msg.event;
        if (ev?.type === "content_block_delta" && ev.delta?.type === "text_delta") {
          this.send({ t: "delta", text: ev.delta.text });
        } else if (ev?.type === "content_block_delta" && ev.delta?.type === "thinking_delta" && ev.delta.thinking) {
          this.send({ t: "thinking_delta", text: ev.delta.thinking });
        } else if (ev?.type === "message_start") {
          this.status.begin(); // a queued turn starting after the previous result
        } else if (ev?.type === "content_block_start") {
          // Status line phase (proposal 32) — the block's content stays dropped.
          const b = ev.content_block;
          if (b?.type === "tool_use") this.status.set("tool", b.name ?? null);
          else if (b?.type === "text") this.status.set("writing");
          else this.status.set("thinking");
        }
        break;
      }
      case "assistant": {
        const blocks = contentBlocks(msg.message?.content);
        const text = blocks.filter((b) => b.type === "text").map((b) => b.text).join("");
        // Summarized thinking (empty when the model didn't think or display is omitted).
        const thought = blocks.filter((b) => b.type === "thinking").map((b) => b.thinking ?? "").join("");
        if (thought) {
          this.insert("thinking", thought, null);
          this.send({ t: "thinking", text: thought });
        }
        if (text) {
          this.insert("assistant", text, null);
          this.send({ t: "assistant", text });
        }
        for (const b of blocks.filter((b) => b.type === "tool_use")) {
          this.insert("tool", null, JSON.stringify({ id: b.id, name: b.name, input: b.input }));
          this.send({ t: "tool_use", id: b.id, name: b.name, input: b.input });
        }
        break;
      }
      case "user": {
        // The SDK feeds tool results back as a user turn (proposal 07). Surface
        // each, keyed by the tool_use id, and fold it onto the stored tool row so
        // a reattach replays the result under its call.
        const blocks = contentBlocks(msg.message?.content);
        for (const b of blocks.filter((b) => b.type === "tool_result")) {
          const content = toolResultText(b.content);
          const images = toolResultImages(this.db, this.id, b.content);
          this.attachToolResult(b.tool_use_id, content, !!b.is_error, images);
          this.send({
            t: "tool_result",
            toolUseID: b.tool_use_id,
            content,
            isError: !!b.is_error,
            ...(images.length ? { images } : {}),
          });
        }
        this.status.set("thinking");
        break;
      }
      case "result": {
        // total_cost_usd and modelUsage are CUMULATIVE for the conversation (spend.ts) → record deltas.
        const cost = cumulativeCostDelta(this.db, this.id, msg.total_cost_usd ?? 0);
        // Still accumulate the API-equivalent cost in the DB (audit/telemetry), but
        // it's no longer surfaced — on a Max subscription it's not a real charge.
        this.db
          .prepare("UPDATE sessions SET total_cost_usd = total_cost_usd + ? WHERE id = ?")
          .run(cost, this.id);
        this.insert("result", null, JSON.stringify({ subtype: msg.subtype, cost }));
        // Spend ledger (ADR 0017): one row per model the turn used (subagents may
        // run a different model than the session's).
        for (const [model, u] of Object.entries((msg.modelUsage ?? {}) as Record<string, any>)) {
          recordCumulative(this.db, {
            sessionId: this.id,
            provider: "anthropic",
            model,
            input: u?.inputTokens,
            output: u?.outputTokens,
            cacheRead: u?.cacheReadInputTokens,
            cacheWrite: u?.cacheCreationInputTokens,
            cost: u?.costUSD,
          });
        }
        this.send({ t: "result", subtype: msg.subtype });
        this.status.end();
        if (this.sockets.size === 0) this.notify("done");
        // Refresh the Max-plan meters after a turn (cached; ~1-min TTL).
        this.emitUsage();
        this.emitContext();
        this.flushTitleRefine();
        break;
      }
    }
  }

  // ---- helpers -------------------------------------------------------------

  private insert(role: string, content: string | null, toolJson: string | null, sdkUuid: string | null = null): string {
    const id = randomUUID();
    this.db
      .prepare("INSERT INTO messages (id, session_id, role, content, tool_json, ts, sdk_uuid) VALUES (?,?,?,?,?,?,?)")
      .run(id, this.id, role, content, toolJson, nowIso(), sdkUuid);
    return id;
  }

  // Fold a tool result onto its tool_use row (proposal 07) so history replay shows
  // it under the call. The tool_use id lives inside tool_json; match the latest row
  // carrying it (ids are unique, so at most one).
  private attachToolResult(toolUseId: string, content: string, isError: boolean, images: string[] = []): void {
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
    if (images.length) j.images = images;
    this.db.prepare("UPDATE messages SET tool_json = ? WHERE id = ?").run(JSON.stringify(j), row.id);
  }

  // Upgrade the first turn's heuristic title with a one-shot model call (ADR 0009).
  // Fire-and-forget and consume-once — never blocks or fails the turn.
  private flushTitleRefine(): void {
    const prompt = this.titlePrompt;
    if (!prompt) return;
    this.titlePrompt = null;
    void refineTitle(this.db, this.id, this.cwd, prompt, (f) => this.send(f), this.queryFn as any).catch(() => {});
  }

  private send(frame: Record<string, unknown>): void {
    // An approval / question card blocks the turn on the user (status line).
    if (frame.t === "permission_request" || frame.t === "user_dialog") this.status.wait();
    for (const ws of this.sockets) this.sendTo(ws, frame);
  }

  // Fetch (cached) Max-plan usage and push it to the client as a `usage` frame.
  // Fire-and-forget + fail-soft: usage is best-effort telemetry, never on the
  // turn's critical path. `ws` targets a specific socket (reattach); omit to
  // broadcast to the currently attached one.
  private emitUsage(ws?: WebSocket): void {
    getUsage()
      .then((usage) => {
        if (!usage) return;
        const frame = { t: "usage", usage };
        if (ws) this.sendTo(ws, frame);
        else this.send(frame);
      })
      .catch(() => {});
  }

  private sendTo(ws: WebSocket, frame: Record<string, unknown>): void {
    if (ws.readyState === ws.OPEN) ws.send(JSON.stringify(frame));
  }
}

export type ClaudeRegistry = Map<string, EngineSession>;

// Periodically evict detached, idle Claude sessions to bound RAM on a small host
// (each live session is an Agent SDK subprocess). Returns a stop fn. Production
// only — server.ts starts it; tests drive sessions directly. unref'd so it never
// keeps the process alive on its own.
export function startIdleReaper(
  registry: ClaudeRegistry,
  db: DB,
  idleMs = IDLE_REAP_MS,
  intervalMs = REAP_INTERVAL_MS,
): () => void {
  const timer = setInterval(() => {
    for (const [id, session] of registry) {
      if (!session.isReapable(idleMs)) continue;
      session.stop();
      registry.delete(id);
      logEvent(db, "session.reap", null, id);
    }
  }, intervalMs);
  timer.unref?.();
  return () => clearInterval(timer);
}
