// The engine abstraction (ADR 0008). A chat session is served by one of two
// engines — ClaudeSession (Agent SDK, claude.ts) or NativeSession (Vercel AI SDK,
// native.ts) — chosen per session by the model's provider (session-ws.ts). Both
// speak the SAME claude-ws.md wire, so the Flutter UI, the WS handler, the DELETE
// route, and the idle reaper all drive them through this one interface without
// knowing which engine is behind it.

import type { WebSocket } from "ws";

// Session mode (proposal 25). The client names one of these three; the daemon
// maps it to an SDK permissionMode + gate setting itself — a raw SDK mode string
// (bypassPermissions, …) is never accepted off the wire (security.md #5).
export const SESSION_MODES = ["ask", "auto", "plan"] as const;
export type SessionMode = (typeof SESSION_MODES)[number];
export const DEFAULT_MODE: SessionMode = "auto"; // proposal 18: daemon default is auto-allow

export function parseMode(x: unknown): SessionMode | null {
  return typeof x === "string" && (SESSION_MODES as readonly string[]).includes(x) ? (x as SessionMode) : null;
}

// Query.rewindFiles() result (SDK RewindFilesResult). `filesChanged` are ABSOLUTE
// paths; a real (non-dry) run returns no file list (M8 spike).
export type RewindResult = {
  canRewind: boolean;
  error?: string;
  filesChanged?: string[];
  insertions?: number;
  deletions?: number;
  skippedLinks?: number;
};

export interface EngineSession {
  // Start the model loop (Claude: resume via id; native: replay transcript).
  start(resumeId?: string | null): void;
  // Attach a client socket: send history, replay pending approvals. Never starts.
  attach(ws: WebSocket): void;
  // Client socket closed — keep running for the next reattach. Never stops.
  // Removes only [ws]; other attached clients keep receiving frames.
  detach(ws: WebSocket): void;
  // A user turn (text + optional uploaded image ids).
  pushUser(text: string, imageIds?: string[], from?: WebSocket): void;
  // Answer a pending tool-approval request.
  // deviceId = the paired device that answered, for the audit trail
  // (security.md #5). Null when unknown (e.g. an auto-allow flush).
  // Returns false when nothing was waiting on that id.
  onPermission(toolUseID: string, allow: boolean, deviceId?: string | null): boolean;
  // Toggle per-session auto-approval of tool permissions.
  setAutoAllow(on: boolean): void;
  // Switch the session mode (proposal 25). deviceId = who asked (audit). Returns
  // false when unchanged or unsupported by the engine (native has no 'plan').
  setMode(mode: SessionMode, deviceId?: string | null): boolean;
  // Answer a blocking dialog (AskUserQuestion etc.) — Claude-only; native no-ops.
  onDialogResponse(dialogId: string, completed: boolean, result: unknown, deviceId?: string | null): boolean;
  // Waiting permission_request / user_dialog frames — what a push notification
  // shows (GET /sessions/:id/pending, ADR 0013).
  pending(): { permissions: Record<string, unknown>[]; dialogs: Record<string, unknown>[] };
  // Cancel the in-flight turn without ending the session.
  interrupt(): void;
  // MCP servers (proposal 43) — Claude-only; absent on the native engine.
  sendMcpStatus?(): void;
  mcpAction?(server: string, action: string, deviceId?: string | null): Promise<boolean>;
  // Compact the conversation now — Claude-only; absent on the native engine.
  compact?(deviceId?: string | null): boolean;
  // Change reasoning effort live — Claude-only; absent on the native engine.
  setEffort?(level: string | null, deviceId?: string | null): Promise<boolean>;
  // Switch model live — Claude-only; absent on the native engine.
  setModel?(model: string, deviceId?: string | null): Promise<boolean>;
  // File checkpoint rewind (ADR 0023) — Claude-only; absent on the native engine.
  rewind?(sdkUuid: string, dryRun: boolean): Promise<RewindResult>;
  // True while a turn is running (rewind is refused mid-turn).
  busy?(): boolean;
  // Tell attached clients a rewind happened ({t:"rewound"}).
  announceRewound?(messageId: string, files: string[]): void;
  // Tear the session down for good (DELETE /sessions/:id, or the reaper) and close
  // every attached socket with [code] (default 1012: clients reconnect).
  stop(code?: number, reason?: string): void;
  // Detached + idle past idleMs → the reaper may evict it.
  isReapable(idleMs: number): boolean;
}

export type EngineRegistry = Map<string, EngineSession>;
