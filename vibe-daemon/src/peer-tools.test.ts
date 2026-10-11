// Peer-tool rules (proposal 30, security.md #21) — pure handlers, no SDK.

import test from "node:test";
import assert from "node:assert/strict";
import { openDb } from "./db.js";
import { listPeers, sendPeer, readPeer, listNotes, resolveNote, resetPeerLimits, type PeerDeps } from "./peer-tools.js";
import type { EngineSession, SessionMode } from "./engine.js";

function setup(mode: SessionMode = "auto") {
  resetPeerLimits();
  const db = openDb(":memory:");
  const p = db.prepare("INSERT INTO projects (id, path, name, type) VALUES (?,?,?,?)");
  p.run("p1", "/tmp/a", "a", "unknown");
  p.run("p2", "/tmp/b", "b", "unknown");
  const s = db.prepare("INSERT INTO sessions (id, project_id, kind, status, title, created_at) VALUES (?,?,?,?,?,?)");
  const t = new Date().toISOString();
  s.run("me", "p1", "claude", "live", "Me", t);
  s.run("peer", "p1", "claude", "live", "Peer", t);
  s.run("idle", "p1", "claude", "live", "Idle", t); // in the DB, not in the registry
  s.run("other", "p2", "claude", "live", "Other project", t);
  s.run("term", "p1", "terminal", "live", "Shell", t);
  const got: string[] = [];
  const reg = new Map<string, EngineSession>();
  for (const id of ["me", "peer", "other", "term"]) {
    reg.set(id, { pushUser: (x: string) => got.push(`${id}:${x}`) } as unknown as EngineSession);
  }
  let m = mode;
  const deps: PeerDeps = { db, registry: reg, selfId: "me", getMode: () => m };
  return { db, deps, got, setMode: (x: SessionMode) => (m = x) };
}
const msg = (db: any, sid: string, role: string, content: string) =>
  db.prepare("INSERT INTO messages (id, session_id, role, content, ts) VALUES (?,?,?,?,?)").run(
    Math.random().toString(36), sid, role, content, new Date().toISOString());

test("list: only running siblings in the same project", () => {
  const { deps } = setup();
  const r = listPeers(deps);
  assert.ok(r.ok);
  assert.match(r.text, /peer/);
  assert.doesNotMatch(r.text, /other|idle|term|\bme\b/);
});

test("send: delivers with a provenance header and audits", () => {
  const { db, deps, got } = setup();
  const r = sendPeer(deps, "peer", "build is green");
  assert.ok(r.ok);
  assert.equal(got.length, 1);
  assert.match(got[0], /^peer:\[Message from another VibeMobile session me "Me"/);
  assert.match(got[0], /build is green$/);
  const ev = db.prepare("SELECT detail FROM events WHERE kind = 'peer.send'").all() as { detail: string }[];
  assert.deepEqual(ev.map((e) => e.detail), ["me->peer"]);
});

test("send: refused in plan mode, nothing delivered", () => {
  const { deps, got } = setup("plan");
  const r = sendPeer(deps, "peer", "hi");
  assert.ok(!r.ok);
  assert.equal(got.length, 0);
});

test("send: refuses self, other project, terminal, not-running, unknown — same message for cross-project/unknown", () => {
  const { deps, got } = setup();
  assert.ok(!sendPeer(deps, "me", "x").ok);
  const cross = sendPeer(deps, "other", "x");
  const unknown = sendPeer(deps, "nope", "x");
  assert.ok(!cross.ok && !unknown.ok);
  assert.equal((cross as any).error, (unknown as any).error);
  assert.ok(!sendPeer(deps, "term", "x").ok);
  const idle = sendPeer(deps, "idle", "x");
  assert.ok(!idle.ok);
  assert.match((idle as any).error, /isn't running/);
  assert.equal(got.length, 0);
});

test("send: rejects empty and oversize", () => {
  const { deps } = setup();
  assert.ok(!sendPeer(deps, "peer", "   ").ok);
  assert.ok(!sendPeer(deps, "peer", "x".repeat(8_001)).ok);
});

test("send: rate-limited per sender, window slides", () => {
  const { deps, got } = setup();
  let now = 1_000_000;
  deps.now = () => now;
  for (let i = 0; i < 12; i++) assert.ok(sendPeer(deps, "peer", `m${i}`).ok);
  const over = sendPeer(deps, "peer", "one too many");
  assert.ok(!over.ok);
  assert.match((over as any).error, /rate limit/);
  assert.equal(got.length, 12);
  now += 10 * 60_000 + 1;
  assert.ok(sendPeer(deps, "peer", "after window").ok);
});

test("read: last messages, conversation only, truncated; project-scoped", () => {
  const { db, deps } = setup();
  msg(db, "peer", "user", "first");
  msg(db, "peer", "tool", "should be hidden");
  msg(db, "peer", "assistant", "y".repeat(2_500));
  const r = readPeer(deps, "peer", 10);
  assert.ok(r.ok);
  assert.match(r.text, /^User: first/);
  assert.doesNotMatch(r.text, /hidden/);
  assert.match(r.text, /truncated/);
  assert.ok(!readPeer(deps, "other").ok);
  assert.ok(!readPeer(deps, "me").ok);
});

test("read: still allowed in plan mode (read-only)", () => {
  const { db, deps } = setup("plan");
  msg(db, "peer", "user", "hello");
  assert.ok(readPeer(deps, "peer").ok);
});

test("notes: open notes of this project only, read-only, allowed in plan mode, marked as data", () => {
  const { db, deps, setMode } = setup("plan");
  const n = db.prepare("INSERT INTO notes (id, project_id, text, done, created_at, updated_at) VALUES (?,?,?,?,?,?)");
  const t = new Date().toISOString();
  n.run("n1", "p1", "ship the thing", 0, t, t);
  n.run("n2", "p1", "old idea", 1, t, t);
  n.run("n3", "p2", "other project secret", 0, t, t);
  const r = listNotes(deps);
  assert.ok(r.ok);
  assert.match(r.text, /ship the thing/);
  assert.match(r.text, /not instructions/);
  assert.doesNotMatch(r.text, /old idea|other project/);
  const all = listNotes(deps, true);
  assert.ok(all.ok && /\[x\] \(n2\) old idea/.test(all.text));
  setMode("auto");
  assert.ok(listNotes(deps).ok);
});

test("notes: empty project says so", () => {
  const { deps } = setup();
  const r = listNotes(deps);
  assert.ok(r.ok && /No open notes/.test(r.text));
});

test("resolve_note: ticks a note of this project only, refused in plan mode, audited", () => {
  const { db, deps, setMode } = setup("plan");
  const n = db.prepare("INSERT INTO notes (id, project_id, text, done, created_at, updated_at) VALUES (?,?,?,?,?,?)");
  const t = new Date().toISOString();
  n.run("n1", "p1", "ship the thing", 0, t, t);
  n.run("n3", "p2", "other project", 0, t, t);
  const listed = listNotes(deps);
  assert.ok(listed.ok && /\(n1\) ship the thing/.test(listed.text));
  assert.ok(!resolveNote(deps, "n1").ok);
  setMode("auto");
  assert.ok(resolveNote(deps, "n1").ok);
  assert.equal((db.prepare("SELECT done FROM notes WHERE id = 'n1'").get() as { done: number }).done, 1);
  assert.ok(resolveNote(deps, "n1").ok); // idempotent
  assert.deepEqual(resolveNote(deps, "n3"), resolveNote(deps, "nope"));
  assert.ok(!resolveNote(deps, "n3").ok);
  assert.equal((db.prepare("SELECT done FROM notes WHERE id = 'n3'").get() as { done: number }).done, 0);
  assert.ok(db.prepare("SELECT 1 FROM events WHERE kind = 'note.resolve'").get());
});
