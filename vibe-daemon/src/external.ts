// Mirror + reply to a `claude` CLI session that is still running on the server
// (ADR 0012, security.md #16). Read side works for any running CLI; write side
// only for one started with `vc` (tmux -L vc, session name vc-*).
//
// Built on Claude Code's own ~/.claude/sessions/<pid>.json registry — an
// internal format, so everything here fails soft: no registry / no match ⇒ the
// session just isn't "running externally" and the normal SDK path applies.

import { execFile, spawn } from "node:child_process";
import { chmodSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, openSync, readSync, closeSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { randomUUID } from "node:crypto";
import { promisify } from "node:util";
import * as pty from "node-pty";
import type { WebSocket } from "ws";
import type { DB } from "./db.js";
import { logEvent } from "./auth.js";
import { pathInRoots } from "./paths.js";
import { currentTitle } from "./titler.js";
import { defaultClaudeProjectsRoot, encodeProjectPath } from "./discover.js";
import { aiTitleOf, applyAiTitle, importTranscriptText, toolResultText } from "./transcript-import.js";
import { toolResultImages } from "./attachments.js";

const execFileP = promisify(execFile);

export type RunningCli = { pid: number; sessionId: string; cwd: string; status: string };

const sessionsDir = () => process.env.VIBE_CLAUDE_SESSIONS_DIR ?? join(homedir(), ".claude", "sessions");
const procRoot = () => process.env.VIBE_PROC_ROOT ?? "/proc";

// Fields 4 (parent pid) and 22 (process start time) of /proc/<pid>/stat. The
// comm field (2) may contain spaces/parens, so split after the LAST ')'.
// Fields 3.. follow it.
function procStatOf(pid: number): { ppid: string; start: string } | null {
  try {
    const stat = readFileSync(join(procRoot(), String(pid), "stat"), "utf8");
    const f = stat.slice(stat.lastIndexOf(")") + 2).split(" ");
    return { ppid: f[1], start: f[19] };
  } catch {
    return null;
  }
}

// Running CLI sessions keyed by Claude session id. An entry counts only if its
// pid is alive AND started when the registry says (pid-reuse guard).
export function runningCliSessions(): Map<string, RunningCli> {
  const out = new Map<string, RunningCli>();
  let files: string[];
  try {
    files = readdirSync(sessionsDir()).filter((f) => f.endsWith(".json"));
  } catch {
    return out;
  }
  for (const f of files) {
    try {
      const j = JSON.parse(readFileSync(join(sessionsDir(), f), "utf8"));
      if (typeof j.pid !== "number" || typeof j.sessionId !== "string" || typeof j.cwd !== "string") continue;
      const stat = procStatOf(j.pid);
      if (stat?.start !== String(j.procStart)) continue;
      // The daemon's own Agent SDK subprocess registers here too. It is not an
      // external CLI — mirroring it would stop() the very loop it belongs to.
      if (stat.ppid === String(process.pid)) continue;
      out.set(j.sessionId, { pid: j.pid, sessionId: j.sessionId, cwd: j.cwd, status: String(j.status ?? "") });
    } catch {
      // unreadable / mid-write — skip this tick
    }
  }
  return out;
}

// ---- tmux -L vc (write side) ------------------------------------------------
// The daemon never STARTS this server: list/paste/send-keys/attach all fail
// (harmlessly) when no server exists, so it always lives in the operator's
// login session, not the daemon's cgroup (ADR 0012).

// Keys the daemon may send. Digits + Tab drive the CLI's AskUserQuestion menu.
export type VcKey = "Enter" | "Escape" | "Tab" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9";

export type VcTmux = {
  panes(): Promise<{ name: string; pid: number }[]>;
  paste(name: string, text: string): Promise<void>;
  key(name: string, key: VcKey): Promise<void>;
  attach(name: string, cols: number, rows: number): pty.IPty;
};

export function realVcTmux(socket = process.env.VIBE_VC_TMUX_SOCKET ?? "vc"): VcTmux {
  const target = (name: string) => `=${name}:`; // exact session name, active pane
  return {
    async panes() {
      try {
        const { stdout } = await execFileP("tmux", ["-L", socket, "list-panes", "-a", "-F", "#{session_name}\t#{pane_pid}"]);
        return stdout
          .split("\n")
          .filter(Boolean)
          .map((l) => {
            const [name, pid] = l.split("\t");
            return { name, pid: Number(pid) };
          });
      } catch {
        return []; // no server / tmux missing
      }
    },
    // Text via STDIN into a one-shot buffer — never argv, so it can't be read as a
    // tmux command or key name. -p = bracketed paste (multi-line = one message).
    async paste(name, text) {
      const buf = `vibe-${randomUUID()}`;
      await new Promise<void>((res, rej) => {
        const p = spawn("tmux", ["-L", socket, "load-buffer", "-b", buf, "-"], { stdio: ["pipe", "ignore", "ignore"] });
        p.on("error", rej);
        p.on("exit", (code) => (code === 0 ? res() : rej(new Error(`load-buffer exited ${code}`))));
        p.stdin.end(text);
      });
      await execFileP("tmux", ["-L", socket, "paste-buffer", "-d", "-p", "-b", buf, "-t", target(name)]);
    },
    async key(name, key) {
      await execFileP("tmux", ["-L", socket, "send-keys", "-t", target(name), key]);
    },
    // A second tmux client alongside the PC's. No detach-client (pty-ws.ts does
    // that for its own sessions) — the operator's VS Code view must stay.
    attach(name, cols, rows) {
      return pty.spawn("tmux", ["-L", socket, "attach", "-t", target(name)], {
        name: "xterm-256color",
        cols,
        rows,
        env: process.env as Record<string, string>,
      });
    },
  };
}

export type External = { cli: RunningCli; pane: string | null };

// The CLI's AskUserQuestion menu as keystrokes (ADR 0012 addendum, verified on
// Claude Code 2.1.291). Per question: single-select → the option's digit, which
// selects and moves on; multi-select → each chosen digit toggles, Tab moves on.
// More than one question, or any multi-select, ends on a review screen where
// "1" submits. `answers` maps question text → label (multi: ", "-joined), the
// same contract as the SDK path (claude-ws.md). null = an answer that isn't one
// of the offered labels (e.g. free text) — the caller types nothing.
export function questionKeys(questions: any[], answers: Record<string, unknown>): VcKey[] | null {
  if (!Array.isArray(questions) || !questions.length) return null;
  const keys: VcKey[] = [];
  for (const q of questions) {
    const labels: string[] = (Array.isArray(q?.options) ? q.options : []).map((o: any) => String(o?.label));
    const a = answers[q?.question];
    if (typeof a !== "string") return null;
    const picked = new Set(labels.includes(a) ? [a] : a.split(", "));
    const idx = [...picked].map((l) => labels.indexOf(l));
    if (!idx.length || idx.some((i) => i < 0 || i > 8)) return null;
    if (q.multiSelect) keys.push(...idx.map((i) => String(i + 1) as VcKey), "Tab");
    else if (idx.length === 1) keys.push(String(idx[0] + 1) as VcKey);
    else return null;
  }
  if (questions.length > 1 || questions.some((q) => q?.multiSelect)) keys.push("1");
  return keys;
}

// Is this row's Claude session running in a CLI right now, and can we reply to
// it? Resolved from server-side state only — the client never names a pane.
export async function resolveExternal(
  claudeSessionId: string | null,
  projectPath: string,
  vc: VcTmux,
): Promise<External | null> {
  if (!claudeSessionId) return null;
  const cli = runningCliSessions().get(claudeSessionId);
  if (!cli) return null;
  let pane: string | null = null;
  if (resolve(cli.cwd) === resolve(projectPath) && pathInRoots(projectPath)) {
    pane = (await vc.panes()).find((p) => p.name.startsWith("vc-") && p.pid === cli.pid)?.name ?? null;
  }
  return { cli, pane };
}

// ---- mirror mode ------------------------------------------------------------

// Serve one WS client from the CLI's transcript instead of the Agent SDK. The
// transcript is canonical while the CLI owns the session, so `messages` is
// rebuilt from it on attach and appended as it grows. Closes 4410 when the CLI
// exits — the client's retry lands on the normal SDK resume path.
// ---- images into a running CLI (ADR 0012 addendum 2026-10-06) ---------------
// A running `claude` CLI takes an image only as a file path pasted on its own
// (it turns into `[Image #N]`). Attachments live as SQLite BLOBs (security.md
// #8), so a mirrored reply exports them here first: a daemon-owned 0700 dir,
// 0600 files named by the server-minted attachment id, swept after 24 h.
export const mirrorImageDir = () => process.env.VIBE_MIRROR_IMAGE_DIR ?? join(homedir(), ".cache", "vibe-daemon", "mirror-images");
const IMAGE_TTL_MS = 24 * 3_600_000;
const EXT: Record<string, string> = { "image/png": "png", "image/jpeg": "jpg", "image/webp": "webp", "image/gif": "gif" };

// Export this row's attachments → absolute paths, in order. Ids not owned by the
// row (or unknown) are skipped — same ownership gate as ClaudeSession.pushUser.
export function exportMirrorImages(db: DB, rowId: string, ids: string[], dir = mirrorImageDir()): string[] {
  if (!ids.length) return [];
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  chmodSync(dir, 0o700);
  for (const f of readdirSync(dir)) {
    try {
      if (Date.now() - statSync(join(dir, f)).mtimeMs > IMAGE_TTL_MS) rmSync(join(dir, f));
    } catch {
      /* raced with another sweep */
    }
  }
  const out: string[] = [];
  for (const id of ids) {
    if (!/^a_[0-9a-f]+$/.test(id)) continue; // server-minted shape only → safe file name
    const row = db.prepare("SELECT media_type, data FROM attachments WHERE id = ? AND session_id = ?").get(id, rowId) as
      | { media_type: string; data: Buffer }
      | undefined;
    const ext = row && EXT[row.media_type];
    if (!row || !ext) continue;
    const file = join(dir, `${id}.${ext}`);
    writeFileSync(file, row.data, { mode: 0o600 });
    out.push(file);
  }
  return out;
}

export class Mirror {
  // Rows a phone is watching right now, so the CLI hook (hook.ts) doesn't push
  // what the phone already shows.
  private static live = new Set<Mirror>();
  static watching(rowId: string): boolean {
    for (const m of Mirror.live) if (m.rowId === rowId) return true;
    return false;
  }

  private offset = 0;
  private timer: NodeJS.Timeout;
  // An AskUserQuestion the CLI is showing right now (tool_use with no result yet).
  private question: { id: string; input: any } | null = null;
  private status: string;
  private readonly path: string;

  constructor(
    private db: DB,
    private rowId: string,
    private claudeSessionId: string,
    private cwd: string,
    private ext: External,
    private ws: WebSocket,
    private vc: VcTmux,
  ) {
    Mirror.live.add(this);
    this.status = ext.cli.status;
    this.path = join(defaultClaudeProjectsRoot(), encodeProjectPath(cwd), `${claudeSessionId}.jsonl`);
    this.db.prepare("DELETE FROM messages WHERE session_id = ?").run(rowId);
    importTranscriptText(db, rowId, cwd, this.readNew());
    const messages = db
      .prepare("SELECT role, content, tool_json, ts FROM messages WHERE session_id = ? ORDER BY ts")
      .all(rowId);
    this.send({ t: "history", messages });
    const title = currentTitle(db, rowId);
    if (title) this.send({ t: "title", title });
    this.sendExternal();
    // Attached while the CLI is waiting on a question: the import folded every
    // answered one, so a result-less AskUserQuestion row is still open.
    const ask = db
      .prepare("SELECT tool_json FROM messages WHERE session_id = ? AND role = 'tool' AND tool_json LIKE '%\"name\":\"AskUserQuestion\"%' ORDER BY ts DESC LIMIT 1")
      .get(rowId) as { tool_json: string } | undefined;
    const j = ask ? JSON.parse(ask.tool_json) : null;
    if (j && !("result" in j)) this.ask(j.id, j.input);
    this.timer = setInterval(() => this.tick(), Number(process.env.VIBE_MIRROR_POLL_MS ?? 1000));
  }

  stop(): void {
    clearInterval(this.timer);
    Mirror.live.delete(this);
  }

  async reply(text: string, deviceId: string | null, imageIds: string[] = []): Promise<void> {
    const pane = await this.pane();
    if (!pane) return this.readOnly();
    const images = exportMirrorImages(this.db, this.rowId, imageIds);
    // Each path is its own bracketed paste — that's what the CLI turns into an image.
    if (text) await this.vc.paste(pane, images.length ? `${text} ` : text);
    for (const [i, path] of images.entries()) await this.vc.paste(pane, i ? ` ${path}` : path);
    await this.vc.key(pane, "Enter");
    logEvent(this.db, "external.input", deviceId, images.length ? `${this.rowId}:images=${images.length}` : this.rowId);
  }

  async interrupt(deviceId: string | null): Promise<void> {
    const pane = await this.pane();
    if (!pane) return this.readOnly();
    await this.vc.key(pane, "Escape");
    logEvent(this.db, "external.interrupt", deviceId, this.rowId);
  }

  // The phone's answer to a mirrored AskUserQuestion, typed into the CLI's menu.
  // dialogId is the tool_use id. Same pane resolution + audit as reply().
  async answer(dialogId: string, completed: boolean, result: unknown, deviceId: string | null): Promise<void> {
    const pane = await this.pane();
    if (!pane) return this.readOnly();
    this.drain(); // answered on the PC meanwhile? then there's nothing to type into
    const q = this.question;
    if (!q || q.id !== dialogId) return;
    if (!completed) {
      await this.vc.key(pane, "Escape");
    } else {
      const keys = questionKeys(q.input?.questions, (result as any)?.answers ?? {});
      if (!keys) {
        this.send({ t: "error", message: "That answer can't be typed into the CLI — use the Terminal view." });
        return this.sendQuestion();
      }
      // One send-keys per key, spaced, so the TUI never reads two as one input.
      const gap = Number(process.env.VIBE_VC_KEY_DELAY_MS ?? 150);
      for (const k of keys) {
        await this.vc.key(pane, k);
        await new Promise((r) => setTimeout(r, gap));
      }
    }
    logEvent(this.db, "external.dialog", deviceId, this.rowId);
  }

  private ask(id: string, input: any): void {
    this.question = { id, input };
    this.sendQuestion();
  }

  // Same user_dialog frame the SDK path uses, so the app's question card renders it.
  private sendQuestion(): void {
    const q = this.question;
    if (q) this.send({ t: "user_dialog", dialogId: q.id, dialogKind: "ask_user_question", payload: q.input, toolUseID: q.id });
  }

  // Re-resolved on every input (security.md #16) — never trust a cached pane.
  private async pane(): Promise<string | null> {
    return (await resolveExternal(this.claudeSessionId, this.cwd, this.vc))?.pane ?? null;
  }

  private readOnly(): void {
    this.send({ t: "error", message: "Running on the server outside vc — read-only. Start it with `vc` to reply from here." });
  }

  private sendExternal(): void {
    this.send({ t: "external", status: this.status, canReply: this.ext.pane !== null });
  }

  // Complete lines appended since the last read ("" if none / file gone). A
  // trailing partial line (CLI mid-write) is left for the next tick.
  private readNew(): string {
    let size: number;
    try {
      size = statSync(this.path).size;
    } catch {
      return "";
    }
    if (size <= this.offset) return "";
    const buf = Buffer.alloc(size - this.offset);
    const fd = openSync(this.path, "r");
    try {
      readSync(fd, buf, 0, buf.length, this.offset);
    } finally {
      closeSync(fd);
    }
    const end = buf.lastIndexOf(0x0a) + 1;
    this.offset += end;
    return buf.subarray(0, end).toString("utf8");
  }

  private drain(): void {
    for (const line of this.readNew().split("\n")) if (line.trim()) this.apply(line);
  }

  private tick(): void {
    this.drain();
    const cli = runningCliSessions().get(this.claudeSessionId);
    if (!cli || cli.pid !== this.ext.cli.pid) {
      this.stop();
      if (this.ws.readyState === this.ws.OPEN) this.ws.close(4410, "external session ended");
      return;
    }
    if (cli.status !== this.status) {
      this.status = cli.status;
      this.sendExternal();
    }
  }

  // One new transcript line → DB row(s) + frames, same shapes as claude.ts's
  // live handle() so the client renders it exactly like an SDK turn.
  private apply(line: string): void {
    let msg: any;
    try {
      msg = JSON.parse(line);
    } catch {
      return;
    }
    if (msg.type === "ai-title") {
      const ai = aiTitleOf(line);
      const title = ai && applyAiTitle(this.db, this.rowId, this.cwd, ai);
      if (title) this.send({ t: "title", title, auto: true });
      return;
    }
    if (msg.isSidechain || (msg.type !== "user" && msg.type !== "assistant")) return;
    const content = msg.message?.content;
    const blocks: any[] = Array.isArray(content) ? content : [];
    const text = typeof content === "string" ? content : blocks.filter((b) => b.type === "text").map((b) => b.text).join("");
    const ts = typeof msg.timestamp === "string" ? msg.timestamp : new Date().toISOString();
    if (msg.type === "assistant") {
      if (text) {
        this.insert("assistant", text, null, ts);
        this.send({ t: "assistant", text });
      }
      for (const b of blocks.filter((b) => b.type === "tool_use")) {
        this.insert("tool", null, JSON.stringify({ id: b.id, name: b.name, input: b.input }), ts);
        this.send({ t: "tool_use", id: b.id, name: b.name, input: b.input });
        if (b.name === "AskUserQuestion") this.ask(b.id, b.input);
      }
      return;
    }
    if (text) {
      this.insert("user", text, null, ts);
      this.send({ t: "user_turn", text });
    }
    for (const b of blocks.filter((b) => b.type === "tool_result")) {
      const result = toolResultText(b.content);
      const images = toolResultImages(this.db, this.rowId, b.content);
      this.foldToolResult(b.tool_use_id, result, !!b.is_error, images);
      this.send({
        t: "tool_result",
        toolUseID: b.tool_use_id,
        content: result,
        isError: !!b.is_error,
        ...(images.length ? { images } : {}),
      });
      if (this.question?.id === b.tool_use_id) {
        this.question = null;
        this.send({ t: "dialog_closed", dialogId: b.tool_use_id }); // answered (here or on the PC)
      }
    }
  }

  private insert(role: string, content: string | null, toolJson: string | null, ts: string): void {
    this.db
      .prepare("INSERT INTO messages (id, session_id, role, content, tool_json, ts) VALUES (?,?,?,?,?,?)")
      .run(randomUUID(), this.rowId, role, content, toolJson, ts);
  }

  private foldToolResult(toolUseId: string, content: string, isError: boolean, images: string[]): void {
    const row = this.db
      .prepare("SELECT id, tool_json FROM messages WHERE session_id = ? AND role = 'tool' AND tool_json LIKE ? ORDER BY ts DESC LIMIT 1")
      .get(this.rowId, `%"id":"${toolUseId}"%`) as { id: string; tool_json: string } | undefined;
    if (!row) return;
    const j = JSON.parse(row.tool_json);
    j.result = content;
    j.isError = isError;
    if (images.length) j.images = images;
    this.db.prepare("UPDATE messages SET tool_json = ? WHERE id = ?").run(JSON.stringify(j), row.id);
  }

  private send(frame: Record<string, unknown>): void {
    if (this.ws.readyState === this.ws.OPEN) this.ws.send(JSON.stringify(frame));
  }
}
