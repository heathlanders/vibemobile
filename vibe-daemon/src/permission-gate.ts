// Shared tool-permission gate (security.md #5, ADR 0008). Lifted verbatim from
// ClaudeSession so BOTH engines — the Agent SDK (claude.ts) and the native Vercel
// AI SDK engine (native.ts) — approve tool calls through the SAME code path. A
// native tool that skips this gate is a shell-over-network hole; keeping one
// implementation (guarded by the existing claude.test.ts gate tests) is how we
// keep it correct.
//
// Behavior (unchanged from claude.ts): auto-allow is ON by default (every call
// approved immediately + audited); with it off, each call emits a
// `permission_request` frame and blocks until the phone answers, denies on
// timeout, and replays a pending request on reattach. Every decision
// (auto_allow / allow / deny / timeout) is written to the `events` audit log.
//
// AskUserQuestion and other `user_dialog` round-trips stay in claude.ts — they are
// Claude-specific and not a tool-permission decision.

import { randomUUID } from "node:crypto";
import type { DB } from "./db.js";
import { logEvent } from "./auth.js";
import { previewForTool } from "./diff-preview.js";

export type PermissionDecision =
  | { behavior: "allow"; updatedInput: Record<string, unknown> }
  | { behavior: "deny"; message: string };

type Pending = { resolve: (r: PermissionDecision) => void; req: Record<string, unknown> };

export class PermissionGate {
  private pending = new Map<string, Pending>();
  private autoAllow = true; // default ON (claude-ws.md)

  constructor(
    private readonly db: DB,
    private readonly sessionId: string,
    private readonly send: (frame: Record<string, unknown>) => void,
    private readonly timeoutMs: number,
    // Session cwd, used only to render a project-relative path in the diff
    // preview. Absent ⇒ the absolute path is shown.
    private readonly cwd: string | null = null,
    // Called after a request is raised — the engine pushes to the phone from
    // here when no client is attached (push.ts, ADR 0013).
    private readonly onRequest: () => void = () => {},
    // Auto-allow applies only when this says the call is in scope (file-scope.ts);
    // out of scope → ask the phone even in Auto mode. Absent ⇒ everything in scope.
    private readonly inScope: (toolName: string, input: Record<string, unknown>) => boolean = () => true,
  ) {}

  get autoAllowOn(): boolean {
    return this.autoAllow;
  }

  // Approve a tool call. With auto-allow on, approve + audit immediately. Else ask
  // the phone and deny on timeout (or if no client is attached — the frame just
  // isn't delivered and the timeout fires). Resolved by onPermission().
  request(
    toolName: string,
    input: Record<string, unknown>,
    opts?: { toolUseID?: string; title?: string; displayName?: string; description?: string },
  ): Promise<PermissionDecision> {
    if (this.autoAllow) {
      if (this.inScope(toolName, input)) {
        logEvent(this.db, "permission.auto_allow", null, `${this.sessionId}:${toolName}`);
        return Promise.resolve({ behavior: "allow", updatedInput: input });
      }
      logEvent(this.db, "permission.out_of_scope", null, `${this.sessionId}:${toolName}`);
    }
    const toolUseID = opts?.toolUseID ?? randomUUID();
    const req = {
      t: "permission_request",
      toolUseID,
      toolName,
      title: opts?.title,
      displayName: opts?.displayName,
      description: opts?.description,
      input,
      // Proposal 02: for file-writing tools, a diff of what will change. Built
      // from `input` — the very object resolved as `updatedInput` below — so
      // what the card renders is what the tool executes. Absent for every other
      // tool, and old clients simply ignore it.
      diffPreview: previewForTool(toolName, input, this.cwd) ?? undefined,
    };
    return new Promise((resolve) => {
      this.pending.set(toolUseID, { resolve, req });
      this.send(req);
      this.onRequest();
      setTimeout(() => {
        if (this.pending.delete(toolUseID)) {
          logEvent(this.db, "permission.timeout", null, `${this.sessionId}:${toolName}`);
          this.send({ t: "permission_closed", toolUseID }); // other devices drop the card
          resolve({ behavior: "deny", message: "Approval timed out" });
        }
      }, this.timeoutMs);
    });
  }

  // `deviceId` is the paired device that answered — without it the audit log
  // records that a shell command was approved but not by whom (security.md #5).
  // Null only where there is genuinely no human actor (auto-allow, timeout).
  // False when nothing was waiting (already answered, timed out) — the REST
  // answer route turns that into a 410.
  onPermission(toolUseID: string, allow: boolean, deviceId: string | null = null): boolean {
    const p = this.pending.get(toolUseID);
    if (!p) return false;
    this.pending.delete(toolUseID);
    this.send({ t: "permission_closed", toolUseID }); // first answer wins; other devices drop the card
    logEvent(
      this.db,
      allow ? "permission.allow" : "permission.deny",
      deviceId,
      `${this.sessionId}:${p.req.toolName as string}`,
    );
    p.resolve(
      allow
        ? { behavior: "allow", updatedInput: p.req.input as Record<string, unknown> }
        : { behavior: "deny", message: "User denied" },
    );
    return true;
  }

  // Toggle auto-approval. Turning it ON flushes any request already waiting on the
  // phone (a mid-approval toggle unblocks the turn).
  setAutoAllow(on: boolean): void {
    this.autoAllow = on;
    if (!on) return;
    for (const [toolUseID, p] of this.pending) {
      this.pending.delete(toolUseID);
      logEvent(this.db, "permission.auto_allow", null, `${this.sessionId}:${p.req.toolName as string}`);
      this.send({ t: "permission_closed", toolUseID });
      p.resolve({ behavior: "allow", updatedInput: p.req.input as Record<string, unknown> });
    }
  }

  // The waiting permission_request frames, for GET /sessions/:id/pending.
  pendingRequests(): Record<string, unknown>[] {
    return [...this.pending.values()].map((p) => p.req);
  }

  // Re-send pending requests to a freshly-attached client (roam mid-approval recovers).
  replay(send: (frame: Record<string, unknown>) => void): void {
    for (const { req } of this.pending.values()) send(req);
  }

  // Session ending: resolve everything as deny so no turn hangs.
  resolveAllDenied(): void {
    for (const [toolUseID, p] of this.pending) {
      this.send({ t: "permission_closed", toolUseID });
      p.resolve({ behavior: "deny", message: "session ended" });
    }
    this.pending.clear();
  }
}
