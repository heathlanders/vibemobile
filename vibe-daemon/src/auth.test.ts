// M1 auth verification (CLAUDE.md §4 goal-driven). Each test is a security
// property: unpaired rejected, pairing works once, codes expire, tokens revoke.
// Drives the real app via app.inject() against an in-memory DB — no network.

import test from "node:test";
import assert from "node:assert/strict";
import { openDb } from "./db.js";
import { authFailLimiter, buildApp } from "./app.js";
import { createPairingCode } from "./auth.js";

async function setup() {
  const db = openDb(":memory:");
  const app = await buildApp(db);
  return { db, app };
}

const pair = (app: Awaited<ReturnType<typeof setup>>["app"], code: string, name = "pixel") =>
  app.inject({ method: "POST", url: "/pair", payload: { code, device_name: name } });

test("unpaired request is rejected 401", async () => {
  const { app } = await setup();
  const res = await app.inject({ method: "GET", url: "/devices" });
  assert.equal(res.statusCode, 401);
});

test("valid code issues a token that authenticates", async () => {
  const { db, app } = await setup();
  const res = await pair(app, createPairingCode(db));
  assert.equal(res.statusCode, 201);
  const { token, device_id } = res.json();
  assert.ok(token && device_id);
  const ok = await app.inject({ method: "GET", url: "/devices", headers: { authorization: `Bearer ${token}` } });
  assert.equal(ok.statusCode, 200);
  assert.equal(ok.json().length, 1);
});

test("pairing code is single-use", async () => {
  const { db, app } = await setup();
  const code = createPairingCode(db);
  assert.equal((await pair(app, code, "a")).statusCode, 201);
  assert.equal((await pair(app, code, "b")).statusCode, 401);
});

test("expired pairing code is rejected", async () => {
  const { db, app } = await setup();
  const code = createPairingCode(db, -1); // already expired
  assert.equal((await pair(app, code)).statusCode, 401);
});

test("dashed code format is accepted", async () => {
  const { db, app } = await setup();
  const code = createPairingCode(db);
  const dashed = `${code.slice(0, 4)}-${code.slice(4)}`;
  assert.equal((await pair(app, dashed)).statusCode, 201);
});

test("bad token is rejected", async () => {
  const { app } = await setup();
  const res = await app.inject({ method: "GET", url: "/devices", headers: { authorization: "Bearer deadbeef" } });
  assert.equal(res.statusCode, 401);
});

test("revoked device token stops working", async () => {
  const { db, app } = await setup();
  const { token, device_id } = (await pair(app, createPairingCode(db))).json();
  const headers = { authorization: `Bearer ${token}` };
  assert.equal((await app.inject({ method: "GET", url: "/devices", headers })).statusCode, 200);
  const del = await app.inject({ method: "DELETE", url: `/devices/${device_id}`, headers });
  assert.equal(del.statusCode, 204);
  assert.equal((await app.inject({ method: "GET", url: "/devices", headers })).statusCode, 401);
});

test("health is public", async () => {
  const { app } = await setup();
  assert.equal((await app.inject({ method: "GET", url: "/health" })).statusCode, 200);
});

test("authFailLimiter: trips at max, audits once, resets after the window", () => {
  let t = 0;
  const l = authFailLimiter(3, 1000, () => t);
  assert.deepEqual([l.fail("a"), l.fail("a"), l.fail("a"), l.fail("a")], [false, false, true, false]);
  assert.equal(l.blocked("a"), true);
  assert.equal(l.blocked("b"), false, "per IP");
  t = 1000;
  assert.equal(l.blocked("a"), false, "window over");
});

test("failed auth is limited per tailnet client (X-Forwarded-For from loopback only)", async () => {
  const { db, app } = await setup();
  const { token } = (await pair(app, createPairingCode(db))).json();
  const from = (ip: string, auth = "Bearer nope") =>
    app.inject({ method: "GET", url: "/projects", headers: { authorization: auth, "x-forwarded-for": ip } });

  for (let i = 0; i < 20; i++) assert.equal((await from("100.64.0.9")).statusCode, 401);
  assert.equal((await from("100.64.0.9")).statusCode, 429, "tripped");
  assert.equal((await from("100.64.0.9", `Bearer ${token}`)).statusCode, 429, "blocked even with a good token until the window ends");
  assert.equal((await from("100.64.0.7", `Bearer ${token}`)).statusCode, 200, "another client unaffected");
  const ev = db.prepare("SELECT detail FROM events WHERE kind = 'auth.ratelimit'").all() as any[];
  assert.deepEqual(ev.map((e) => e.detail), ["100.64.0.9"], "audited once with the client IP");

  // A non-loopback peer can't pick its bucket via a forged header.
  const forged = await app.inject({
    method: "GET",
    url: "/projects",
    remoteAddress: "10.0.0.5",
    headers: { authorization: `Bearer ${token}`, "x-forwarded-for": "100.64.0.9" },
  });
  assert.equal(forged.statusCode, 200);
});
