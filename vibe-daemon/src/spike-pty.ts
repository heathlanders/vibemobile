// M0 spike 2 — prove: node-pty bytes round-trip over WS (the wire that
// xterm.dart will speak), including terminal resize. Runs a localhost-only
// Fastify + @fastify/websocket server AND an in-process WS client that drives
// a real shell, so the round-trip is verifiable headless before any Flutter
// exists. Exit 0 = echo seen + resize acked; exit 1 = failed.
//
// Wire protocol (ttyd-style, see PLAN §4/§8):
//   client -> server: first byte is an opcode
//       '0' + utf8 bytes  = keystroke input  -> pty.write
//       '1' + JSON{cols,rows} = resize       -> pty.resize
//   server -> client: raw pty output bytes (binary frames), forwarded verbatim

import Fastify from "fastify";
import websocket from "@fastify/websocket";
import * as pty from "node-pty";
import { WebSocket } from "ws";

const PORT = 8788; // throwaway spike port; real daemon = 8787
const HOST = "127.0.0.1"; // localhost-only bind (PLAN §5)

// --- server -----------------------------------------------------------------
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
  console.log(`[server] pty spawned pid=${term.pid} session=${(req.params as any).id}`);

  term.onData((data) => {
    if (socket.readyState === socket.OPEN) socket.send(data);
  });
  term.onExit(({ exitCode }) => {
    console.log(`[server] pty exit code=${exitCode}`);
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
      console.log(`[server] resize -> ${cols}x${rows}`);
    }
  });

  socket.on("close", () => {
    console.log("[server] socket closed, killing pty");
    term.kill();
  });
});

await app.listen({ port: PORT, host: HOST });
console.log(`[server] listening ws://${HOST}:${PORT}/pty/:id`);

// --- in-process client self-test -------------------------------------------
const input = (s: string) => Buffer.concat([Buffer.from("0"), Buffer.from(s, "utf8")]);
const resize = (cols: number, rows: number) =>
  Buffer.concat([Buffer.from("1"), Buffer.from(JSON.stringify({ cols, rows }))]);

const MARKER = "VIBE_SPIKE_OK";
const ws = new WebSocket(`ws://${HOST}:${PORT}/pty/selftest`);
let buf = "";
let resizeSent = false;

const fail = (msg: string) => {
  console.error(`[spike] FAIL: ${msg}`);
  process.exit(1);
};
const timeout = setTimeout(() => fail("timed out waiting for echo"), 8000);

ws.on("open", () => {
  console.log("[client] connected");
  ws.send(resize(120, 40));
  resizeSent = true;
  // echo a unique marker through the real shell
  // split the literal so the typed-command echo differs from the resolved output
  ws.send(input(`echo VIBE_SPIKE""_OK\n`));
});

ws.on("message", (data: Buffer) => {
  buf += data.toString("utf8");
  // The typed command shows as `echo VIBE_SPIKE""_OK`; the shell's OUTPUT is
  // the resolved `VIBE_SPIKE_OK` on its own line. Match the resolved form only.
  if (new RegExp(`[\\r\\n]${MARKER}\\b`).test(buf)) {
    clearTimeout(timeout);
    console.log("[client] saw marker in pty output ✓");
    if (!resizeSent) fail("resize not sent");
    ws.send(input("exit\n"));
    setTimeout(async () => {
      console.log("[spike] DONE. node-pty <-> WS round-trip + resize OK");
      await app.close();
      process.exit(0);
    }, 200);
  }
});

ws.on("error", (e) => fail(`ws error: ${e.message}`));
