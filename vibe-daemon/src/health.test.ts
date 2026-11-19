// Proposal 69 R5: a real /health, a 500 handler that logs and never leaks the
// error text, and a graceful stop that closes sockets 1012 and the DB.
import test from "node:test";
import assert from "node:assert/strict";
import { WebSocket } from "ws";
import type { AddressInfo } from "node:net";
import { openDb } from "./db.js";
import { buildApp } from "./app.js";
import { createPairingCode } from "./auth.js";
import { stopDaemon } from "./shutdown.js";

test("/health reports uptime, live sessions and DB state; 503 when the DB is gone", async (t) => {
  const db = openDb(":memory:");
  const registry = new Map();
  const app = await buildApp(db, undefined, registry);
  t.after(() => app.close());
  const ok = await app.inject({ method: "GET", url: "/health" });
  assert.equal(ok.statusCode, 200);
  const body = ok.json();
  assert.equal(body.ok, true);
  assert.equal(body.db, true);
  assert.equal(body.sessions, 0);
  assert.equal(typeof body.uptimeSec, "number");
  db.close();
  const down = await app.inject({ method: "GET", url: "/health" });
  assert.equal(down.statusCode, 503);
  assert.equal(down.json().ok, false);
});

test("an unexpected error is a 500 without its message", async (t) => {
  const db = openDb(":memory:");
  const app = await buildApp(db);
  t.after(() => app.close());
  app.get("/boom", async () => {
    throw new Error("ENOENT /home/someone/secret");
  });
  const { token } = (
    await app.inject({ method: "POST", url: "/pair", payload: { code: createPairingCode(db), device_name: "t" } })
  ).json();
  const res = await app.inject({ method: "GET", url: "/boom", headers: { authorization: `Bearer ${token}` } });
  assert.equal(res.statusCode, 500);
  assert.deepEqual(res.json(), { error: "internal error" });
  assert.doesNotMatch(res.body, /secret|ENOENT/);
});

test("stopDaemon closes open sockets 1012 and the DB", async () => {
  const db = openDb(":memory:");
  const app = await buildApp(db);
  app.get("/ws-test", { websocket: true }, () => {});
  await app.listen({ host: "127.0.0.1", port: 0 });
  const port = (app.server.address() as AddressInfo).port;
  const { token } = (
    await app.inject({ method: "POST", url: "/pair", payload: { code: createPairingCode(db), device_name: "t" } })
  ).json();
  const ws = new WebSocket(`ws://127.0.0.1:${port}/ws-test`, { headers: { authorization: `Bearer ${token}` } });
  await new Promise<void>((r) => ws.on("open", () => r()));
  const closed = new Promise<number>((r) => ws.on("close", (c) => r(c)));
  await stopDaemon(app, db);
  assert.equal(await closed, 1012, "clients told the server is restarting");
  assert.equal(db.open, false);
});
