// Audit-log read surface (security.md #14) + device list `current` flag.
// Read-only by design: the log is the record of what happened, so the API
// exposes no way to change it.

import test from "node:test";
import assert from "node:assert/strict";
import { openDb } from "./db.js";
import { buildApp } from "./app.js";
import { createPairingCode, logEvent } from "./auth.js";

async function setup() {
  const db = openDb(":memory:");
  const app = await buildApp(db);
  const { token, device_id } = (
    await app.inject({ method: "POST", url: "/pair", payload: { code: createPairingCode(db), device_name: "pixel" } })
  ).json();
  return { db, app, auth: { authorization: `Bearer ${token}` }, deviceId: device_id as string };
}

const get = (app: any, auth: any, url: string) => app.inject({ method: "GET", url, headers: auth });

test("events are returned newest-first and capped at the server maximum", async () => {
  const { db, app, auth } = await setup();
  for (let i = 0; i < 5; i++) logEvent(db, "session.create", null, `s${i}`);

  const res = await get(app, auth, "/events?limit=9999");
  assert.equal(res.statusCode, 200);
  const rows = res.json();
  assert.ok(rows.length <= 200);
  const ts = rows.map((r: any) => r.ts);
  assert.deepEqual(ts, [...ts].sort().reverse(), "newest first");
});

test("kind filter matches by prefix", async () => {
  const { db, app, auth } = await setup();
  logEvent(db, "permission.allow", null, "s1:Edit");
  logEvent(db, "permission.deny", null, "s1:Bash");
  logEvent(db, "session.create", null, "s1");

  const rows = (await get(app, auth, "/events?kind=permission")).json();
  assert.equal(rows.length, 2);
  assert.ok(rows.every((r: any) => r.kind.startsWith("permission.")));
});

test("before= pages backwards through the log", async () => {
  const { db, app, auth } = await setup();
  for (let i = 0; i < 4; i++) logEvent(db, "session.create", null, `s${i}`);

  const first = (await get(app, auth, "/events?limit=2")).json();
  const older = (await get(app, auth, `/events?limit=2&before=${encodeURIComponent(first[1].ts)}`)).json();
  assert.ok(older.every((r: any) => r.ts < first[1].ts), "the second page is strictly older");
});

test("the audit read is not itself audited (no self-amplification)", async () => {
  const { db, app, auth } = await setup();
  const before = (db.prepare("SELECT COUNT(*) c FROM events").get() as any).c;
  await get(app, auth, "/events");
  await get(app, auth, "/events");
  const after = (db.prepare("SELECT COUNT(*) c FROM events").get() as any).c;
  assert.equal(after, before);
});

test("the log is read-only over REST", async () => {
  const { app, auth } = await setup();
  for (const method of ["DELETE", "PATCH", "POST"] as const) {
    const res = await app.inject({ method, url: "/events", headers: auth });
    assert.ok(res.statusCode === 404 || res.statusCode === 405, `${method} /events must not be routed`);
  }
});

test("events require a bearer token", async () => {
  const { app } = await setup();
  assert.equal((await app.inject({ method: "GET", url: "/events" })).statusCode, 401);
});

test("device list flags the calling device as current", async () => {
  const { app, auth, deviceId } = await setup();
  const rows = (await get(app, auth, "/devices")).json();
  const me = rows.find((r: any) => r.id === deviceId);
  assert.equal(me.current, true);
});
