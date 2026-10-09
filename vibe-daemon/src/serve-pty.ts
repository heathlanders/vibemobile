// SUPERSEDED (M2) — kept as an M0 artifact only. The real terminal path is now
// the attach-only, tmux-backed `pty-ws.ts` (registered in app.ts). This file is
// create-on-connect + kill-on-close (wrong for reattach) and is no longer wired
// into the daemon. Don't extend it; see docs/protocols/reattach.md / ADR 0004.
//
// M0 live test — the SERVER half of spike-pty.ts, kept running so a real
// xterm.dart client (the Flutter app / its live integration test) can attach a
// shell over the wire. Same protocol as spike-pty.ts; no in-process self-test
// client, so it stays up until killed.
//
// Wire (docs/protocols/pty-ws.md): client->server first byte = ASCII opcode
//   '0' + utf8 = keystroke -> pty.write ; '1' + JSON{cols,rows} = resize.
//   server->client: raw pty bytes, verbatim binary frames.

import Fastify from "fastify";
import websocket from "@fastify/websocket";
import * as pty from "node-pty";

const PORT = Number(process.env.PORT ?? 8788);
const HOST = "127.0.0.1"; // localhost-only bind (PLAN §5)

const app = Fastify();
await app.register(websocket);

app.get("/pty/:id", { websocket: true }, (socket, req) => {
  const shell = process.env.SHELL ?? "/bin/bash";
  const term = pty.spawn(shell, [], {
    name: "xterm-256color",
    cols: 80,
    rows: 24,
    cwd: process.env.HOME,
    env: process.env as Record<string, string>,
  });
  console.log(`[serve] pty pid=${term.pid} session=${(req.params as any).id}`);

  term.onData((data) => {
    if (socket.readyState === socket.OPEN) socket.send(data);
  });
  term.onExit(({ exitCode }) => {
    console.log(`[serve] pty exit code=${exitCode}`);
    if (socket.readyState === socket.OPEN) socket.close();
  });

  socket.on("message", (raw: Buffer) => {
    const op = String.fromCharCode(raw[0]);
    const body = raw.subarray(1);
    if (op === "0") {
      term.write(body.toString("utf8"));
    } else if (op === "1") {
      const { cols, rows } = JSON.parse(body.toString("utf8"));
      term.resize(cols, rows);
    }
  });

  socket.on("close", () => term.kill());
});

await app.listen({ port: PORT, host: HOST });
console.log(`[serve] listening ws://${HOST}:${PORT}/pty/:id  (Ctrl-C to stop)`);
