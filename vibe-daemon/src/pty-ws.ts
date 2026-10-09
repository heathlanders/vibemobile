// Attach-only PTY WebSocket (protocols/reattach.md + pty-ws.md, ADR 0003/0004).
// Replaces the create-on-connect serve-pty.ts spike. Connecting = attaching to an
// EXISTING tmux session (created out-of-band via POST /sessions). First-open and
// reconnect take the identical path. Auth = the global bearer hook in app.ts
// (rejects the upgrade with 401 ≈ client 4401). tmux is injected.
//
// Wire (unchanged): client→server first byte ASCII '0' = keystroke, '1' = resize
// JSON; server→client raw PTY bytes verbatim. Liveness rides WS ping/pong, never
// the byte stream.

import type { FastifyInstance } from "fastify";
import type { WebSocket } from "ws";
import type { DB } from "./db.js";
import type { Tmux } from "./tmux.js";
import type { Device } from "./auth.js";
import { inputAudit } from "./input-audit.js";

const PING_MS = 15_000;

export function registerPtyWs(app: FastifyInstance, db: DB, tmux: Tmux): void {
  app.get("/pty/:id", { websocket: true }, async (socket: WebSocket, req) => {
    const { id } = req.params as { id: string };

    // Attach-only: a session must already exist. A miss (never created, or tmux
    // gone after reboot) is an honest 4404 — never resurrect as a blank shell.
    if (!(await tmux.hasSession(id))) {
      db.prepare("UPDATE sessions SET status = 'stale' WHERE id = ?").run(id);
      socket.close(4404, "session not found");
      return;
    }

    await tmux.detachOthers(id); // sole live client (resize safety, reattach.md)
    const term = tmux.attach(id, 80, 24); // client resizes immediately on attach
    db.prepare("UPDATE sessions SET status = 'live' WHERE id = ?").run(id);

    let closing = false;
    const audit = inputAudit(db, "terminal.input", (req as { device?: Device }).device?.id ?? null, id);

    term.onData((data) => {
      if (socket.readyState === socket.OPEN) socket.send(data);
    });
    // The tmux session ended under us (shell exited) → tell the client it's over.
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
        const { cols, rows } = JSON.parse(body.toString("utf8"));
        term.resize(cols, rows);
      }
    });

    // Server heartbeat: reclaim a half-open socket whose client vanished without
    // a close frame. Independent of the client's own pingInterval.
    let isAlive = true;
    socket.on("pong", () => (isAlive = true));
    const heartbeat = setInterval(() => {
      if (!isAlive) return socket.terminate(); // → fires 'close' → detach
      isAlive = false;
      socket.ping();
    }, PING_MS);

    // WS close = DETACH, never kill. Killing the attach pty exits the tmux client;
    // the session (and shell) keep running for the next reattach. kill-session is
    // exclusively DELETE /sessions.
    socket.on("close", () => {
      closing = true;
      clearInterval(heartbeat);
      audit.end();
      term.kill();
    });
  });
}
