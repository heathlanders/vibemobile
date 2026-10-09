// Attachment route verification (proposal 16, security.md #8). Drives the real
// app via inject() against an in-memory DB. The security gate is the focus:
// magic-byte sniff (not the declared type), size cap, session ownership, and a
// blob roundtrip. Raw-body upload — the daemon buffers the bytes, never multipart.

import test from "node:test";
import assert from "node:assert/strict";
import { openDb } from "./db.js";
import { buildApp } from "./app.js";
import { createPairingCode } from "./auth.js";

const PNG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x00]);

async function setup() {
  const db = openDb(":memory:");
  const app = await buildApp(db);
  const { token } = (
    await app.inject({ method: "POST", url: "/pair", payload: { code: createPairingCode(db), device_name: "t" } })
  ).json();
  const auth = { authorization: `Bearer ${token}` };
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES (?,?,?,?)").run("p", "/home/user", "h", "unknown");
  db.prepare("INSERT INTO sessions (id, project_id, kind, created_at) VALUES (?,?,?,?)").run(
    "s_claude",
    "p",
    "claude",
    new Date().toISOString(),
  );
  db.prepare("INSERT INTO sessions (id, project_id, kind, created_at) VALUES (?,?,?,?)").run(
    "s_term",
    "p",
    "terminal",
    new Date().toISOString(),
  );
  return { db, app, auth };
}

const upload = (app: any, auth: any, id: string, body: Buffer) =>
  app.inject({
    method: "POST",
    url: `/sessions/${id}/attachments`,
    headers: { ...auth, "content-type": "application/octet-stream" },
    payload: body,
  });

test("upload requires auth", async () => {
  const { app } = await setup();
  assert.equal((await app.inject({ method: "POST", url: "/sessions/s_claude/attachments", payload: PNG })).statusCode, 401);
});

test("upload rejects a non-claude / missing session (ownership gate)", async () => {
  const { app, auth } = await setup();
  assert.equal((await upload(app, auth, "s_term", PNG)).statusCode, 404);
  assert.equal((await upload(app, auth, "nope", PNG)).statusCode, 404);
});

test("upload sniffs the type from magic bytes, not the declared content-type", async () => {
  const { app, auth } = await setup();
  // Lies that it's a PNG, but the bytes are plain text → 415.
  const res = await upload(app, auth, "s_claude", Buffer.from("not an image"));
  assert.equal(res.statusCode, 415);
});

test("a BMP (Windows clipboard format) → 415, and the rejection is audited", async () => {
  const { app, auth, db } = await setup();
  const bmp = Buffer.concat([Buffer.from("BM"), Buffer.alloc(60)]);
  assert.equal((await upload(app, auth, "s_claude", bmp)).statusCode, 415);
  const ev = db.prepare("SELECT detail, device_id FROM events WHERE kind = 'attachment.reject'").get() as any;
  assert.equal(ev.detail, "s_claude:unsupported_type:62");
  assert.ok(ev.device_id);
});

test("an over-cap body → 413 from the parser bodyLimit, and the rejection is audited", async () => {
  const { app, auth, db } = await setup();
  const big = Buffer.alloc(5 * 1024 * 1024 + 1, 0x89);
  assert.equal((await upload(app, auth, "s_claude", big)).statusCode, 413);
  const ev = db.prepare("SELECT detail FROM events WHERE kind = 'attachment.reject'").get() as any;
  assert.equal(ev.detail, `s_claude:too_large:${big.length}`);
});

test("upload rejects an empty body", async () => {
  const { app, auth } = await setup();
  assert.equal((await upload(app, auth, "s_claude", Buffer.alloc(0))).statusCode, 400);
});

test("upload a PNG → 201, sniffed media type, blob roundtrips through GET", async () => {
  const { app, auth, db } = await setup();
  const res = await upload(app, auth, "s_claude", PNG);
  assert.equal(res.statusCode, 201);
  const { attachmentId, mediaType } = res.json();
  assert.equal(mediaType, "image/png");
  assert.match(attachmentId, /^a_/);

  // Stored against the right session (the ownership filter pushUser relies on).
  const row = db.prepare("SELECT session_id FROM attachments WHERE id = ?").get(attachmentId) as any;
  assert.equal(row.session_id, "s_claude");

  const got = await app.inject({ method: "GET", url: `/attachments/${attachmentId}`, headers: auth });
  assert.equal(got.statusCode, 200);
  assert.equal(got.headers["content-type"], "image/png");
  assert.deepEqual(got.rawPayload, PNG);

  // Upload is audited like a command (security.md #5).
  const ev = db.prepare("SELECT detail FROM events WHERE kind = 'attachment.upload'").get() as any;
  assert.ok(ev.detail.startsWith("s_claude:image/png:"));
});

test("GET an unknown attachment → 404", async () => {
  const { app, auth } = await setup();
  assert.equal((await app.inject({ method: "GET", url: "/attachments/a_missing", headers: auth })).statusCode, 404);
});
