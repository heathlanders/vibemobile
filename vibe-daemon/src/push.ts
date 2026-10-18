// FCM push to paired phones (ADR 0013, security.md #17). Fired when a session
// needs the user — a tool approval, an AskUserQuestion, or a finished turn — and
// no phone is attached to see it on the WS.
//
// The payload is deliberately content-free: {type, sessionId}. It transits
// Google, so no command text, file paths or prompts go in it; the phone fetches
// the details itself over Tailscale (GET /sessions/:id/pending) before it
// renders anything.
//
// Disabled (silent no-op) when the service-account key is absent, so tests, CI
// and an un-configured box never talk to Firebase.

import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { DB } from "./db.js";

export type PushType =
  | "permission"
  | "question"
  | "done"
  // A swarm task reached review (tasks.ts, proposal 65): sessionId is the task's session.
  | "task_review"
  // Merge queue (merge-queue.ts, ADR 0032): an item awaits approval / was bounced. sessionId is the author session.
  | "merge_ready"
  | "merge_bounced"
  // A CLI session outside the daemon (hook.ts, ADR 0014): answered in its terminal.
  | "cli_permission"
  | "cli_question"
  | "cli_waiting"
  // Box health (system.ts, ADR 0019): low memory/disk. sessionId is "".
  | "system_alert"
  // Plan usage (usage.ts, ADR 0020): a window resets soon with capacity unused. sessionId is "".
  | "usage_reset";

const credentialsPath = () =>
  process.env.VIBE_FCM_CREDENTIALS ?? join(homedir(), ".config", "vibe-daemon", "firebase-sa.json");

// Whether push can work at all (credentials file present) — server diagnostics.
export const fcmConfigured = (): boolean => existsSync(credentialsPath());

// Tokens FCM says are dead — the app was uninstalled or its data cleared.
const DEAD_TOKEN = new Set(["messaging/registration-token-not-registered", "messaging/invalid-registration-token"]);

type Messaging = import("firebase-admin/messaging").Messaging;
let messaging: Promise<Messaging | null> | null = null;

// Lazy: firebase-admin is only loaded once there is something to send.
function getMessaging(): Promise<Messaging | null> {
  messaging ??= (async () => {
    const file = credentialsPath();
    if (!existsSync(file)) return null;
    const { initializeApp, cert } = await import("firebase-admin/app");
    const { getMessaging } = await import("firebase-admin/messaging");
    return getMessaging(initializeApp({ credential: cert(file) }, "vibe-push"));
  })().catch((e) => {
    console.error("[vibe-daemon] FCM disabled:", (e as Error)?.message ?? e);
    return null;
  });
  return messaging;
}

// Fire-and-forget: a push failure must never touch the session that caused it.
export function notifyDevices(db: DB, type: PushType, sessionId: string): void {
  const tokens = (db.prepare("SELECT fcm_token FROM devices WHERE fcm_token IS NOT NULL").all() as { fcm_token: string }[]).map(
    (r) => r.fcm_token,
  );
  if (!tokens.length) return;
  void getMessaging()
    .then(async (m) => {
      if (!m) return;
      const res = await m.sendEachForMulticast({
        tokens,
        data: { type, sessionId },
        // A permission request is denied after 120 s, so a later delivery is noise.
        android: { priority: "high", ttl: type === "permission" ? 120_000 : 3_600_000 },
      });
      res.responses.forEach((r, i) => {
        if (!r.success && DEAD_TOKEN.has(r.error?.code ?? "")) {
          db.prepare("UPDATE devices SET fcm_token = NULL WHERE fcm_token = ?").run(tokens[i]);
        }
      });
    })
    .catch((e) => console.error("[vibe-daemon] FCM send failed:", (e as Error)?.message ?? e));
}
