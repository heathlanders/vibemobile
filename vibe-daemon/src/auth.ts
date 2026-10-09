// Device auth (ADR: opaque random token + sha256, DB-backed for revoke — see
// PLAN §2C / docs/security.md). Pairing requires physical server access: a code
// is printed in the server terminal (gen-pairing-code.ts) and redeemed once for
// a long-lived device token. Only hashes are stored; tokens/codes are never
// persisted in the clear.

import { createHash, randomBytes, randomInt, randomUUID } from "node:crypto";
import type { DB } from "./db.js";

export const sha256 = (s: string) => createHash("sha256").update(s).digest("hex");
const nowIso = () => new Date().toISOString();

const PAIR_TTL_MIN = 10;

export function logEvent(db: DB, kind: string, deviceId: string | null, detail = ""): void {
  db.prepare("INSERT INTO events (id, kind, device_id, detail, ts) VALUES (?,?,?,?,?)")
    .run(randomUUID(), kind, deviceId, detail, nowIso());
}

// Mint a single-use, TTL'd pairing code. Returns the plaintext (to print at the
// server); stores only its hash. ttlMin < 0 yields an already-expired code (tests).
export function createPairingCode(db: DB, ttlMin = PAIR_TTL_MIN): string {
  const code = String(randomInt(0, 1e8)).padStart(8, "0"); // 8 digits, user-typeable
  const expires = new Date(Date.now() + ttlMin * 60_000).toISOString();
  db.prepare("INSERT INTO pairing_codes (code_hash, expires_at, used) VALUES (?,?,0)")
    .run(sha256(code), expires);
  return code;
}

// Atomically redeem a code: must exist, be unused, and unexpired. Marks it used.
function redeemPairingCode(db: DB, code: string): boolean {
  const hash = sha256(code.replace(/\D/g, "")); // tolerate "1234-5678" formatting
  const tx = db.transaction((): boolean => {
    const row = db
      .prepare("SELECT expires_at, used FROM pairing_codes WHERE code_hash = ?")
      .get(hash) as { expires_at: string; used: number } | undefined;
    if (!row || row.used) return false;
    if (new Date(row.expires_at).getTime() < Date.now()) return false;
    db.prepare("UPDATE pairing_codes SET used = 1 WHERE code_hash = ?").run(hash);
    return true;
  });
  return tx();
}

// Redeem a code → create a device → return its one-time token (shown once).
export function pairDevice(db: DB, code: string, name: string): { device_id: string; token: string } | null {
  if (!redeemPairingCode(db, code)) return null;
  const token = randomBytes(32).toString("hex"); // 256-bit opaque
  const id = randomUUID();
  db.prepare("INSERT INTO devices (id, name, token_hash, paired_at) VALUES (?,?,?,?)")
    .run(id, name, sha256(token), nowIso());
  logEvent(db, "device.paired", id, name);
  return { device_id: id, token };
}

export type Device = { id: string; name: string; paired_at: string; last_seen: string | null };

// Resolve a "Bearer <token>" header to a device, or null. Touches last_seen.
export function authenticate(db: DB, authHeader: string | undefined): Device | null {
  const m = /^Bearer\s+(.+)$/.exec(authHeader ?? "");
  if (!m) return null;
  const device = db
    .prepare("SELECT id, name, paired_at, last_seen FROM devices WHERE token_hash = ?")
    .get(sha256(m[1])) as Device | undefined;
  if (!device) return null;
  db.prepare("UPDATE devices SET last_seen = ? WHERE id = ?").run(nowIso(), device.id);
  return device;
}
