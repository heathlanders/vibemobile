// tmux session manager (ADR 0004, protocols/reattach.md). Every terminal session
// is a tmux session on a DEDICATED socket `-L vibe` — isolated from the user's
// own tmux server. Control commands run via execFile (array args, no shell → no
// injection surface; ids are server-generated regardless). The interactive
// attach is a node-pty wrapping a tmux *client*: killing that pty DETACHES, the
// session keeps running. Exported as a factory so routes/tests can inject a fake.

import { execFile } from "node:child_process";
import { promisify } from "node:util";
import * as pty from "node-pty";
import type { DB } from "./db.js";

const execFileP = promisify(execFile);
const tmuxName = (id: string) => `vibe-${id}`;

export type Tmux = {
  ensureGlobals(): Promise<void>;
  // [command]: a fixed preset literal (presets.ts) typed into the new shell.
  createSession(id: string, cwd: string, command?: string): Promise<void>;
  hasSession(id: string): Promise<boolean>;
  detachOthers(id: string): Promise<void>;
  attach(id: string, cols: number, rows: number): pty.IPty;
  killSession(id: string): Promise<void>;
  sweepStale(db: DB): Promise<void>;
};

// `socket` = the tmux -L name. Defaults to "vibe" (isolated from the user's own
// tmux); tests pass a throwaway name so they never touch the real session set.
export function realTmux(socket = process.env.VIBE_TMUX_SOCKET ?? "vibe"): Tmux {
  // Run a tmux control command; true on exit 0, false on non-zero (the
  // has-session idiom). Throws only on spawn failure (tmux missing).
  const tmux = async (args: string[]): Promise<boolean> => {
    try {
      await execFileP("tmux", ["-L", socket, ...args]);
      return true;
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code === "ENOENT") throw err; // tmux not installed
      return false; // non-zero exit (has-session miss, kill of a gone session, …)
    }
  };

  return {
    // Set globals ONCE before any create so new panes inherit them. history-limit
    // only affects panes created after it's set → must precede createSession.
    async ensureGlobals() {
      await tmux(["set-option", "-g", "history-limit", "10000"]);
      await tmux(["setw", "-g", "aggressive-resize", "on"]);
    },

    async createSession(id, cwd, command) {
      await tmux(["new-session", "-d", "-s", tmuxName(id), "-x", "80", "-y", "24", "-c", cwd]);
      // Typed, not exec'd: quitting the agent leaves a usable shell, not a dead pane.
      if (command) {
        await tmux(["send-keys", "-t", tmuxName(id), "-l", command]);
        await tmux(["send-keys", "-t", tmuxName(id), "Enter"]);
      }
    },

    hasSession(id) {
      return tmux(["has-session", "-t", tmuxName(id)]);
    },

    // Evict any existing client so the new attach is the sole client — tmux sizes
    // a window to its smallest client, so a lingering stale client shrinks it.
    async detachOthers(id) {
      await tmux(["detach-client", "-s", tmuxName(id)]);
    },

    // The interactive client. Killing this pty kills the tmux *client*, which
    // DETACHES — the session (and its shell) survive. This is the whole point.
    attach(id, cols, rows) {
      return pty.spawn("tmux", ["-L", socket, "attach", "-t", tmuxName(id)], {
        name: "xterm-256color",
        cols,
        rows,
        env: process.env as Record<string, string>,
      });
    },

    async killSession(id) {
      await tmux(["kill-session", "-t", tmuxName(id)]); // false if already gone — fine
    },

    // Boot reconcile (reattach.md): a row marked live whose tmux session is gone
    // (machine rebooted → -L vibe server died) is stale. Survives daemon restart,
    // not reboot.
    async sweepStale(db) {
      const live = db
        .prepare("SELECT id FROM sessions WHERE kind = 'terminal' AND status = 'live'")
        .all() as { id: string }[];
      for (const { id } of live) {
        if (!(await this.hasSession(id))) {
          db.prepare("UPDATE sessions SET status = 'stale' WHERE id = ?").run(id);
        }
      }
    },
  };
}
