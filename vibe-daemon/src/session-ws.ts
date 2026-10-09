// Claude session WebSocket (M3, protocols/claude-ws.md). Attach-only, JSON text
// frames (not raw bytes like /pty/:id). Mirrors pty-ws.ts's auth (global bearer
// hook) / heartbeat / detach-on-close shape. The session lives in the registry,
// decoupled from this socket — close detaches, never stops (stop = DELETE).
//
// queryFn is threaded through so tests can inject a fake Agent SDK.

import { query as sdkQuery } from "@anthropic-ai/claude-agent-sdk";
import type { FastifyInstance } from "fastify";
import type { WebSocket } from "ws";
import type { DB } from "./db.js";
import type { Device } from "./auth.js";
import { ClaudeSession, type ClaudeRegistry } from "./claude.js";
import { NativeSession } from "./native.js";
import { providerFor, isNativeProvider } from "./gateway.js";
import { parseMode, type EngineSession } from "./engine.js";
import { defaultClaudeProjectsRoot, encodeProjectPath } from "./discover.js";
import { importTranscript } from "./transcript-import.js";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { inputAudit } from "./input-audit.js";
import { logEvent } from "./auth.js";
import { Mirror, realVcTmux, resolveExternal, type VcTmux } from "./external.js";
import { maxLive } from "./sessions.js";

const PING_MS = 15_000;

// Reuse a live in-daemon session, or start one. The engine is chosen by the model's
// provider (ADR 0008/0016): native providers (providers.ts) → NativeSession (Vercel AI
// SDK); everything else → ClaudeSession (Agent SDK), resuming via claude_session_id.
export function getOrStart(registry: ClaudeRegistry, db: DB, row: any, queryFn: any, streamTextFn?: any): EngineSession {
  let session = registry.get(row.id);
  if (!session) {
    const project = db.prepare("SELECT path FROM projects WHERE id = ?").get(row.project_id) as
      | { path: string }
      | undefined;
    // A worktree session runs in its own checkout (ADR 0022).
    const cwd = row.worktree_path ?? project?.path ?? process.cwd();
    // A row discovered from an external `claude` CLI transcript (discover.ts)
    // has a claude_session_id but no cached history yet — backfill it from the
    // CLI's own transcript before the first attach so the app's view matches.
    if (row.claude_session_id) {
      const { n } = db.prepare("SELECT COUNT(*) AS n FROM messages WHERE session_id = ?").get(row.id) as { n: number };
      if (n === 0) {
        const jsonlPath = join(defaultClaudeProjectsRoot(), encodeProjectPath(cwd), `${row.claude_session_id}.jsonl`);
        importTranscript(db, row.id, cwd, jsonlPath);
      }
    }
    const mode = parseMode(row.mode) ?? undefined; // persisted mode (proposal 25); undefined → daemon default
    session = isNativeProvider(providerFor(row.model))
      ? new NativeSession(db, row.id, cwd, row.model, streamTextFn, undefined, undefined, undefined, mode)
      : new ClaudeSession(db, row.id, cwd, queryFn, undefined, row.model ?? null, mode);
    if (session instanceof ClaudeSession) session.peerRegistry = registry; // session-to-session tools (proposal 30)
    registry.set(row.id, session);
    // Prime the first turn before the engine starts (proposal 15). Clear it so a
    // reattach (or daemon restart) never re-sends — consume-once.
    if (row.initial_prompt) {
      session.pushUser(row.initial_prompt);
      db.prepare("UPDATE sessions SET initial_prompt = NULL WHERE id = ?").run(row.id);
    }
    session.start(row.claude_session_id); // resume if non-null (Claude); no-op for native
    // Discovered rows start 'stale' (sessions.ts's live cap counts 'live' rows,
    // and a project can have more old transcripts than the cap) — promote on
    // first actual attach, same as a daemon-created row is 'live' from creation.
    db.prepare("UPDATE sessions SET status = 'live' WHERE id = ?").run(row.id);
  }
  return session;
}

export function registerSessionWs(
  app: FastifyInstance,
  db: DB,
  registry: ClaudeRegistry,
  queryFn: any = sdkQuery,
  streamTextFn?: any,
  vc: VcTmux = realVcTmux(),
): void {
  const projectPath = (row: any): string =>
    row.worktree_path ??
    (db.prepare("SELECT path FROM projects WHERE id = ?").get(row.project_id) as { path: string } | undefined)?.path ??
    process.cwd();

  app.get("/session/:id", { websocket: true }, (socket: WebSocket, req) => {
    const { id } = req.params as { id: string };
    const row = db.prepare("SELECT * FROM sessions WHERE id = ?").get(id) as any;
    if (!row || row.kind !== "claude") {
      socket.close(4404, "no claude session");
      return;
    }
    const deviceId = (req as { device?: Device }).device?.id ?? null;

    // A CLI still running this session owns its transcript (ADR 0012): mirror it
    // instead of starting a second writer. Resolution is async, so frames that
    // arrive meanwhile queue behind `ready` rather than being dropped.
    let closed = false;
    const ready: Promise<EngineSession | Mirror | null> = resolveExternal(row.claude_session_id, projectPath(row), vc).then(
      (ext) => {
        if (closed) return null;
        if (ext) {
          // An in-daemon loop on the same transcript would be a second writer.
          registry.get(row.id)?.stop();
          registry.delete(row.id);
          return new Mirror(db, row.id, row.claude_session_id, projectPath(row), ext, socket, vc);
        }
        // A worktree someone deleted by hand: say so, never silently run in the main tree.
        if (row.worktree_path && !existsSync(row.worktree_path)) {
          db.prepare("UPDATE sessions SET status = 'stale' WHERE id = ?").run(row.id);
          registry.get(row.id)?.stop();
          registry.delete(row.id);
          socket.send(JSON.stringify({ t: "error", message: "This session's worktree is missing on the server." }));
          socket.close(4410, "worktree missing");
          return null;
        }
        // Resuming a non-live row (discovered / stale) makes it live — same cap
        // POST /sessions enforces, or opening old sessions would bypass it.
        if (!registry.has(row.id) && row.status !== "live") {
          const { n } = db.prepare("SELECT COUNT(*) AS n FROM sessions WHERE kind = 'claude' AND status = 'live'").get() as { n: number };
          if (n >= maxLive("claude")) {
            logEvent(db, "session.cap", deviceId, `claude:${n}`);
            socket.send(JSON.stringify({ t: "error", message: `Too many live Claude sessions (max ${maxLive("claude")}) — close one first.` }));
            socket.close(4429, "too many live sessions");
            return null;
          }
        }
        const session = getOrStart(registry, db, row, queryFn, streamTextFn);
        session.attach(socket); // sends history + replays any pending permission request
        return session;
      },
    );

    socket.on("message", (raw: Buffer) => {
      let f: any;
      try {
        f = JSON.parse(raw.toString("utf8"));
      } catch {
        return;
      }
      void ready.then((session) => {
        if (!session) return;
        if (session instanceof Mirror) {
          if (f.t === "user" && typeof f.text === "string") {
            const images = Array.isArray(f.images) ? f.images.filter((x: any) => typeof x === "string") : [];
            void session.reply(f.text, deviceId, images).catch(() => {});
          }
          else if (f.t === "interrupt") void session.interrupt(deviceId).catch(() => {});
          else if (f.t === "dialog_response" && typeof f.dialogId === "string")
            void session.answer(f.dialogId, !!f.completed, f.result, deviceId).catch(() => {});
          return; // permission prompts live in the CLI's TUI — answer via /tty
        }
        if (f.t === "user" && typeof f.text === "string")
          session.pushUser(f.text, Array.isArray(f.images) ? f.images.filter((x: any) => typeof x === "string") : []);
        // Attribute the decision to the device that answered (security.md #5).
        else if (f.t === "permission" && typeof f.toolUseID === "string")
          session.onPermission(f.toolUseID, !!f.allow, deviceId);
        else if (f.t === "auto_allow") session.setAutoAllow(!!f.on);
        else if (f.t === "mode") {
          const m = parseMode(f.mode); // whitelist: unknown names are dropped, never forwarded
          if (m) session.setMode(m, deviceId);
        }
        else if (f.t === "dialog_response" && typeof f.dialogId === "string")
          session.onDialogResponse(f.dialogId, !!f.completed, f.result, deviceId);
        else if (f.t === "interrupt") session.interrupt();
        else if (f.t === "set_model" && typeof f.model === "string") void session.setModel?.(f.model, deviceId);
        else if (f.t === "compact") session.compact?.(deviceId);
        else if (f.t === "get_mcp") session.sendMcpStatus?.();
        else if (f.t === "mcp_action" && typeof f.server === "string" && typeof f.action === "string") void session.mcpAction?.(f.server, f.action, deviceId);
        else if (f.t === "set_effort" && (f.effort === null || typeof f.effort === "string")) void session.setEffort?.(f.effort, deviceId);
      });
    });

    // Heartbeat — reclaim a half-open socket (same as pty-ws.ts).
    let isAlive = true;
    socket.on("pong", () => (isAlive = true));
    const heartbeat = setInterval(() => {
      if (!isAlive) return socket.terminate();
      isAlive = false;
      socket.ping();
    }, PING_MS);

    socket.on("close", () => {
      closed = true;
      clearInterval(heartbeat);
      void ready.then((session) => {
        if (session instanceof Mirror) session.stop();
        else session?.detach(socket); // keep the SDK loop running for the next reattach
      });
    });
  });

  // The running CLI's own TUI (ADR 0012) — for what the transcript can't show
  // (permission prompts, menus). pty-ws wire (ADR 0003). Only a vc-* pane
  // resolved server-side from this row; 4404 when there is none.
  app.get("/session/:id/tty", { websocket: true }, async (socket: WebSocket, req) => {
    const { id } = req.params as { id: string };
    const row = db.prepare("SELECT * FROM sessions WHERE id = ?").get(id) as any;
    const pane = row?.kind === "claude" ? (await resolveExternal(row.claude_session_id, projectPath(row), vc))?.pane : null;
    if (!pane) {
      socket.close(4404, "no running vc session");
      return;
    }
    logEvent(db, "external.tty", (req as { device?: Device }).device?.id ?? null, id);
    const term = vc.attach(pane, 80, 24);
    let closing = false;
    const audit = inputAudit(db, "external.tty.input", (req as { device?: Device }).device?.id ?? null, id);
    term.onData((data) => {
      if (socket.readyState === socket.OPEN) socket.send(data);
    });
    term.onExit(() => {
      if (!closing && socket.readyState === socket.OPEN) socket.close(4404, "session ended");
    });
    socket.on("message", (raw: Buffer) => {
      const op = String.fromCharCode(raw[0]);
      const body = raw.subarray(1);
      if (op === "0") {
        audit.add(body.length); // size only — never the keystrokes
        term.write(body.toString("utf8"));
      } else if (op === "1") {
        try {
          const { cols, rows } = JSON.parse(body.toString("utf8"));
          term.resize(cols, rows);
        } catch {
          // malformed resize — ignore
        }
      }
    });
    let isAlive = true;
    socket.on("pong", () => (isAlive = true));
    const heartbeat = setInterval(() => {
      if (!isAlive) return socket.terminate();
      isAlive = false;
      socket.ping();
    }, PING_MS);
    socket.on("close", () => {
      closing = true;
      clearInterval(heartbeat);
      audit.end();
      term.kill(); // kills our tmux CLIENT only — the CLI session keeps running
    });
  });
}
