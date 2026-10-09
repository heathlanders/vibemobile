// Turn status line (proposal 32): tells the client whether a turn is running, what
// it's doing, how long it's been going, and how long the model has been quiet —
// so the chat can show "Running Bash… 47s" and spot a stall. Shared by both engines.
//
// Frame: {t:'status', running, phase?, tool?, elapsedMs?, idleMs?}. Durations are
// relative (no clock-skew between phone and box). Sent on phase change, every
// HEARTBEAT_MS while running, on attach (frame()), and once on end.

export type TurnPhase = "thinking" | "writing" | "tool" | "waiting";

export const HEARTBEAT_MS = 5_000;

export class TurnStatus {
  private startedAt: number | null = null;
  private phase: TurnPhase = "thinking";
  private tool: string | null = null;
  private lastActivity = Date.now();
  private beforeWait: { phase: TurnPhase; tool: string | null } | null = null;
  private timer: ReturnType<typeof setInterval> | null = null;

  constructor(
    private readonly send: (frame: Record<string, unknown>) => void,
    private readonly heartbeatMs = HEARTBEAT_MS,
  ) {}

  get running(): boolean {
    return this.startedAt !== null;
  }

  // Start a turn. No-op while one is already running (a message sent mid-turn
  // folds into it).
  begin(): void {
    this.touch();
    if (this.running) return;
    this.startedAt = Date.now();
    this.phase = "thinking";
    this.tool = null;
    this.beforeWait = null;
    this.timer = setInterval(() => this.send(this.frame()), this.heartbeatMs);
    this.timer.unref?.();
    this.send(this.frame());
  }

  // Model/engine activity — resets the idle clock.
  touch(): void {
    this.lastActivity = Date.now();
  }

  // Phase change; emits only when it actually changes. Ignored outside a turn.
  set(phase: TurnPhase, tool: string | null = null): void {
    if (!this.running) return;
    if (this.beforeWait && phase !== "waiting") this.beforeWait = null; // the model moved on
    if (phase === this.phase && tool === this.tool) return;
    this.phase = phase;
    this.tool = tool;
    this.send(this.frame());
  }

  // A permission / question card went out: the turn is blocked on the user.
  wait(): void {
    if (!this.running || this.phase === "waiting") return;
    this.beforeWait = { phase: this.phase, tool: this.tool };
    this.set("waiting");
  }

  // The user answered: back to what the turn was doing.
  resume(): void {
    if (!this.running || this.phase !== "waiting") return;
    const prev = this.beforeWait ?? { phase: "thinking" as TurnPhase, tool: null };
    this.touch();
    this.set(prev.phase, prev.tool);
  }

  end(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
    if (!this.running) return;
    this.startedAt = null;
    this.beforeWait = null;
    this.send(this.frame());
  }

  frame(): Record<string, unknown> {
    if (this.startedAt === null) return { t: "status", running: false };
    const now = Date.now();
    return {
      t: "status",
      running: true,
      phase: this.phase,
      ...(this.tool ? { tool: this.tool } : {}),
      elapsedMs: now - this.startedAt,
      idleMs: now - this.lastActivity,
    };
  }
}
