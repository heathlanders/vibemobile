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

test("a paired device can mint a pairing code that pairs another device", async () => {
  const { db, app } = await setup();
  const { token, device_id } = (await pair(app, createPairingCode(db))).json();
  const res = await app.inject({ method: "POST", url: "/devices/pairing-code", headers: { authorization: `Bearer ${token}` } });
  assert.equal(res.statusCode, 201);
  const { code, expires_at } = res.json();
  assert.match(code, /^[0-9]{4}-[0-9]{4}$/);
  assert.ok(new Date(expires_at).getTime() > Date.now());
  assert.equal((await pair(app, code, "laptop")).statusCode, 201);
  assert.equal((await pair(app, code, "again")).statusCode, 401); // single-use
  const ev = db.prepare("SELECT device_id FROM events WHERE kind = 'pair.code'").get() as { device_id: string };
  assert.equal(ev.device_id, device_id); // audited with the issuer
  const paired = db.prepare("SELECT detail FROM events WHERE kind = 'device.paired' AND detail LIKE 'laptop%'").get() as { detail: string };
  assert.equal(paired.detail, `laptop (code from ${device_id})`); // new device traces to its issuer
});

test("revoking a device kills the pairing codes it minted", async () => {
  const { db, app } = await setup();
  const a = (await pair(app, createPairingCode(db), "phone")).json();
  const b = (await pair(app, createPairingCode(db), "pc")).json();
  const { code } = (
    await app.inject({ method: "POST", url: "/devices/pairing-code", headers: { authorization: `Bearer ${a.token}` } })
  ).json();
  const del = await app.inject({ method: "DELETE", url: `/devices/${a.device_id}`, headers: { authorization: `Bearer ${b.token}` } });
  assert.equal(del.statusCode, 204);
  assert.equal((await pair(app, code, "thief")).statusCode, 401);
  const ev = db.prepare("SELECT detail FROM events WHERE kind = 'device.revoked'").get() as { detail: string };
  assert.equal(ev.detail, `by ${b.device_id}`); // the revoker is on record
});

test("minting pairing codes is rate-limited", async () => {
  const { db, app } = await setup();
  const { token } = (await pair(app, createPairingCode(db))).json();
  const mint = () => app.inject({ method: "POST", url: "/devices/pairing-code", headers: { authorization: `Bearer ${token}` } });
  for (let i = 0; i < 5; i++) assert.equal((await mint()).statusCode, 201);
  assert.equal((await mint()).statusCode, 429);
});

test("minting a pairing code requires auth", async () => {
  const { app } = await setup();
  assert.equal((await app.inject({ method: "POST", url: "/devices/pairing-code" })).statusCode, 401);
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

test("20 wrong /pair codes from 20 forwarded IPs lock pairing until a new code is minted (68 A4)", async () => {
  const { db, app } = await setup();
  const live = createPairingCode(db);
  for (let i = 0; i < 20; i++) {
    const res = await app.inject({
      method: "POST",
      url: "/pair",
      headers: { "x-forwarded-for": `100.64.1.${i}` }, // a fresh IP each try: per-IP limits never trip
      payload: { code: "00000000", device_name: "x" },
    });
    assert.equal(res.statusCode, 401);
  }
  assert.equal((await pair(app, live)).statusCode, 401, "outstanding code burned by the lockout");
  assert.ok(db.prepare("SELECT 1 FROM events WHERE kind = 'pair.lockout'").get(), "lockout audited");
  const fresh = createPairingCode(db);
  assert.equal((await pair(app, "00000000")).statusCode, 401);
  assert.equal((await pair(app, fresh)).statusCode, 201, "a code minted after the lockout works; old failures don't re-burn it");
});

test("a token idle for 61 days is rejected and the device marked expired; 59 days still works (68 A2)", async () => {
  const { db, app } = await setup();
  const a = (await pair(app, createPairingCode(db), "old")).json();
  const b = (await pair(app, createPairingCode(db), "recent")).json();
  const daysAgo = (d: number) => new Date(Date.now() - d * 86_400_000).toISOString();
  db.prepare("UPDATE devices SET last_seen = ? WHERE id = ?").run(daysAgo(61), a.device_id);
  db.prepare("UPDATE devices SET last_seen = ? WHERE id = ?").run(daysAgo(59), b.device_id);
  const get = (token: string) => app.inject({ method: "GET", url: "/devices", headers: { authorization: `Bearer ${token}` } });

  assert.equal((await get(a.token)).statusCode, 401);
  const res = await get(b.token);
  assert.equal(res.statusCode, 200);
  const old = res.json().find((d: any) => d.id === a.device_id);
  assert.ok(old?.expired_at, "kept, marked expired so the Devices screen can say why");
  assert.ok(db.prepare("SELECT 1 FROM events WHERE kind = 'device.expired' AND device_id = ?").get(a.device_id));

  // Expiry sticks: touching last_seen doesn't revive it.
  db.prepare("UPDATE devices SET last_seen = ? WHERE id = ?").run(daysAgo(0), a.device_id);
  assert.equal((await get(a.token)).statusCode, 401);
});

test("a device paired 61 days ago and never used is expired too (68 A2)", async () => {
  const { db, app } = await setup();
  const a = (await pair(app, createPairingCode(db), "unused")).json();
  db.prepare("UPDATE devices SET paired_at = ?, last_seen = NULL WHERE id = ?").run(new Date(Date.now() - 61 * 86_400_000).toISOString(), a.device_id);
  assert.equal((await app.inject({ method: "GET", url: "/devices", headers: { authorization: `Bearer ${a.token}` } })).statusCode, 401);
});
