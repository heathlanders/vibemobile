// The critical wire test (CLAUDE.md: verify streaming against a real PTY/tmux,
// not just units). Real app + real tmux + a real `ws` client over a real socket:
// create a session, attach, type, DROP the socket, reattach the SAME id → tmux
// redraws prior scrollback and the session is still alive. Plus the 4404 path
// (attach a nonexistent session) and WS auth rejection. Skipped if no tmux.

import { REPO_DIR } from "./test-paths.js";
import test from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { randomBytes } from "node:crypto";
import { WebSocket } from "ws";
import type { AddressInfo } from "node:net";
import { openDb } from "./db.js";
import { buildApp } from "./app.js";
import { createPairingCode } from "./auth.js";
import { realTmux } from "./tmux.js";

const execFileP = promisify(execFile);
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const tmuxInstalled = await execFileP("tmux", ["-V"]).then(() => true, () => false);

const SOCK = "vibewstest-" + randomBytes(4).toString("hex");
const OP_INPUT = 0x30; // '0'
const OP_RESIZE = 0x31; // '1'

function frame(op: number, payload: string): Buffer {
  return Buffer.concat([Buffer.from([op]), Buffer.from(payload, "utf8")]);
}

// Connect a ws client; resolve once open (or reject with the close code on a
// pre-open close, e.g. 4404 / auth reject). Collects all text into `out`.
function attach(port: number, id: string, token: string | null) {
  const out = { text: "" };
  const headers = token ? { authorization: `Bearer ${token}` } : {};
  const ws = new WebSocket(`ws://127.0.0.1:${port}/pty/${id}`, { headers });
  ws.on("message", (d: Buffer) => (out.text += d.toString("utf8")));
  const opened = new Promise<void>((resolve, reject) => {
    ws.on("open", () => resolve());
    ws.on("close", (code) => reject(new Error(`closed ${code}`)));
    ws.on("error", () => {}); // close carries the reason
  });
  return { ws, out, opened };
}

test("PTY WS: attach → type → drop → reattach survives", { skip: !tmuxInstalled }, async (t) => {
  const db = openDb(":memory:");
  const tmux = realTmux(SOCK);
  await tmux.ensureGlobals();
  const app = await buildApp(db, tmux);
  await app.listen({ host: "127.0.0.1", port: 0 });
  const port = (app.server.address() as AddressInfo).port;

  t.after(async () => {
    await app.close();
    await execFileP("tmux", ["-L", SOCK, "kill-server"]).catch(() => {});
  });

  // Pair + create a terminal session via REST.
  const { token } = (
    await app.inject({ method: "POST", url: "/pair", payload: { code: createPairingCode(db), device_name: "t" } })
  ).json();
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES (?,?,?,?)").run(
    "p_ok",
    REPO_DIR,
    "vibemobile",
    "unknown",
  );
  const create = await app.inject({
    method: "POST",
    url: "/sessions",
    headers: { authorization: `Bearer ${token}` },
    payload: { project_id: "p_ok", kind: "terminal" },
  });
  assert.equal(create.statusCode, 201);
  const id = create.json().id;

  // First attach: send resize, then a marker command.
  const a = attach(port, id, token);
  await a.opened;
  a.ws.send(frame(OP_RESIZE, JSON.stringify({ cols: 100, rows: 30 })));
  await sleep(200);
  a.ws.send(frame(OP_INPUT, "echo WIRE_$((6*7))\n"));
  await sleep(600);
  assert.match(a.out.text, /WIRE_42/, "marker echoed back over the wire");

  // Drop the socket (simulating IP roam). Session must survive (detach ≠ kill).
  a.ws.close();
  await sleep(400);
  // Input is audited by size and time only — the typed text never reaches events.
  const ev = db.prepare("SELECT kind, detail, device_id FROM events WHERE kind LIKE 'terminal.input%' ORDER BY rowid").all() as any[];
  assert.deepEqual(ev.map((e) => e.kind), ["terminal.input.start", "terminal.input.end"]);
  assert.match(ev[1].detail, new RegExp(`^${id}:bytes=\\d+:secs=\\d+$`));
  assert.ok(ev.every((e) => e.device_id), "attributed to the device");
  assert.doesNotMatch(JSON.stringify(db.prepare("SELECT * FROM events").all()), /WIRE|echo/, "no keystroke content");
  assert.equal(await tmux.hasSession(id), true, "session survives the dropped socket");

  // Reattach SAME id: tmux redraws scrollback (the marker is still there).
  const b = attach(port, id, token);
  await b.opened;
  b.ws.send(frame(OP_RESIZE, JSON.stringify({ cols: 100, rows: 30 })));
  await sleep(600);
  assert.match(b.out.text, /WIRE_42/, "reattach redraws prior scrollback — same shell");
  b.ws.close();
  await sleep(200);
});

test("PTY WS: attaching a nonexistent session closes 4404", { skip: !tmuxInstalled }, async (t) => {
  const db = openDb(":memory:");
  const tmux = realTmux(SOCK + "b");
  const app = await buildApp(db, tmux);
  await app.listen({ host: "127.0.0.1", port: 0 });
  const port = (app.server.address() as AddressInfo).port;
  t.after(async () => {
    await app.close();
    await execFileP("tmux", ["-L", SOCK + "b", "kill-server"]).catch(() => {});
  });

  const { token } = (
    await app.inject({ method: "POST", url: "/pair", payload: { code: createPairingCode(db), device_name: "t" } })
  ).json();

  const code = await new Promise<number>((resolve) => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/pty/s_ghost`, {
      headers: { authorization: `Bearer ${token}` },
    });
    ws.on("close", (c) => resolve(c));
    ws.on("error", () => {});
  });
  assert.equal(code, 4404, "missing session → 4404");
});

test("PTY WS: unauthenticated upgrade is rejected", { skip: !tmuxInstalled }, async (t) => {
  const db = openDb(":memory:");
  const app = await buildApp(db, realTmux(SOCK + "c"));
  await app.listen({ host: "127.0.0.1", port: 0 });
  const port = (app.server.address() as AddressInfo).port;
  t.after(async () => {
    await app.close();
    await execFileP("tmux", ["-L", SOCK + "c", "kill-server"]).catch(() => {});
  });

  const rejected = await new Promise<boolean>((resolve) => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/pty/whatever`); // no token
    ws.on("open", () => resolve(false));
    ws.on("error", () => resolve(true)); // upgrade refused (401)
    ws.on("unexpected-response", () => resolve(true));
  });
  assert.equal(rejected, true, "no bearer token → upgrade refused");
});
