// Terminal input audit (security.md #5, user decision 2026-10-06): log WHEN a
// device typed into a terminal and HOW MUCH, never WHAT. Keystrokes include
// passwords typed at sudo/ssh prompts, so content must never reach the events
// table. One `<kind>.start` on the first input of a connection, one `<kind>.end`
// with the byte count and duration when the socket closes.

import type { DB } from "./db.js";
import { logEvent } from "./auth.js";

export function inputAudit(db: DB, kind: string, deviceId: string | null, sessionId: string) {
  let bytes = 0;
  let startedAt = 0;
  return {
    add(n: number): void {
      if (n <= 0) return;
      if (bytes === 0) {
        startedAt = Date.now();
        logEvent(db, `${kind}.start`, deviceId, sessionId);
      }
      bytes += n;
    },
    end(): void {
      if (bytes === 0) return;
      logEvent(db, `${kind}.end`, deviceId, `${sessionId}:bytes=${bytes}:secs=${Math.round((Date.now() - startedAt) / 1000)}`);
      bytes = 0;
    },
  };
}
