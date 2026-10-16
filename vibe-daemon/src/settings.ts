// Daemon-wide settings (ADR 0026): session rules, disk alert threshold, free-space guard.
//
// A small, strictly whitelisted key/value store. Unknown keys, wrong types and
// out-of-range values are rejected (all-or-nothing); `null` resets a key to its default.
// Every change is audited by key name. These are NOT secrets and grant nothing beyond
// what a paired device can already do (it can already send any prompt to a shell-capable
// session) — but they shape what every session is told, so they are bearer-gated like
// everything else and never accepted from anywhere but the authenticated API.

import { statfsSync } from "node:fs";
import type { FastifyInstance } from "fastify";
import type { DB } from "./db.js";
import { logEvent, type Device } from "./auth.js";

// What every Claude session is told about where data may live (ADR 0025). Advisory —
// the real enforcement is the inherited env vars, Auto-mode file scope and the disk
// guard below. Editable in the app; reset-to-default is `null`.
export const DEFAULT_RULES = `# Storage rules (VibeMobile)
This machine's root SSD (/) is small. Keep it from filling up:
- Never create a cache, build-output, model or data directory on /. Put new caches under /data/cache/<tool>, models under /data/models, large data under /data/volumes/<project>, and new repositories under /data/projects.
- Tool caches are already redirected by environment variables (GRADLE_USER_HOME, PUB_CACHE, ANDROID_HOME, RUSTUP_HOME, OLLAMA_MODELS, PLAYWRIGHT_BROWSERS_PATH). Do not override them, and do not recreate the old locations (~/.gradle, ~/.pub-cache, ~/Android) as real directories.
- /mnt/sdd1 is the media library: never modify it. Backups go only to /mnt/sdd1/backups/.
- Before downloading or building something large (over ~1 GB: images, models, SDKs, full builds), check \`df -h / /data\` and say so.
- If a command would fill a disk, stop and ask instead of running it.`;

type Def =
  | { type: "bool"; default: boolean }
  | { type: "int" | "float"; default: number; min: number; max: number }
  | { type: "text"; default: string; maxLen: number };

export const SETTINGS: Record<string, Def> = {
  "rules.enabled": { type: "bool", default: true },
  "rules.text": { type: "text", default: DEFAULT_RULES, maxLen: 4000 },
  "disk.alert_percent": { type: "int", default: 90, min: 50, max: 99 },
  "disk.min_free_gb": { type: "float", default: 5, min: 0, max: 500 },
  // Alert when the daemon's own data (footprint.ts) passes this many GB. 0 = off.
  "disk.daemon_data_alert_gb": { type: "float", default: 5, min: 0, max: 1000 },
};

export type SettingValue = boolean | number | string;

// Own keys only: a bare `SETTINGS[key]` would resolve "__proto__" / "constructor" /
// "toString" on Object.prototype and treat them as known settings.
const defOf = (key: string): Def | undefined => (Object.hasOwn(SETTINGS, key) ? SETTINGS[key] : undefined);

function validate(key: string, v: unknown): { ok: true; value: SettingValue } | { ok: false; why: string } {
  const d = defOf(key);
  if (!d) return { ok: false, why: "unknown setting" };
  if (d.type === "bool") return typeof v === "boolean" ? { ok: true, value: v } : { ok: false, why: "must be true or false" };
  if (d.type === "text") {
    if (typeof v !== "string") return { ok: false, why: "must be text" };
    if (v.length > d.maxLen) return { ok: false, why: `at most ${d.maxLen} characters` };
    if (v.includes("\0")) return { ok: false, why: "must not contain NUL" };
    return { ok: true, value: v };
  }
  if (typeof v !== "number" || !Number.isFinite(v)) return { ok: false, why: "must be a number" };
  if (d.type === "int" && !Number.isInteger(v)) return { ok: false, why: "must be a whole number" };
  if (v < d.min || v > d.max) return { ok: false, why: `must be between ${d.min} and ${d.max}` };
  return { ok: true, value: v };
}

export function getSetting<T extends SettingValue>(db: DB, key: string): T {
  const d = SETTINGS[key]; // callers pass literal keys
  const row = db.prepare("SELECT value FROM settings WHERE key = ?").get(key) as { value: string } | undefined;
  if (row) {
    try {
      const v = validate(key, JSON.parse(row.value)); // re-validate: a hand-edited row must not poison a session
      if (v.ok) return v.value as T;
    } catch {
      /* fall through to the default */
    }
  }
  return d.default as T;
}

export type SettingView = {
  key: string;
  type: Def["type"];
  value: SettingValue;
  default: SettingValue;
  isDefault: boolean;
  min?: number;
  max?: number;
  maxLen?: number;
};

export function settingsView(db: DB): SettingView[] {
  return Object.entries(SETTINGS).map(([key, d]) => {
    const value = getSetting(db, key);
    return {
      key,
      type: d.type,
      value,
      default: d.default,
      isDefault: value === d.default,
      ...("min" in d ? { min: d.min, max: d.max } : {}),
      ...("maxLen" in d ? { maxLen: d.maxLen } : {}),
    };
  });
}

// All-or-nothing. `null` resets a key to its default.
export function applySettings(
  db: DB,
  updates: Record<string, unknown>,
  deviceId: string | null,
): { ok: true; changed: string[] } | { ok: false; key: string; why: string } {
  const keys = Object.keys(updates);
  const planned: [string, SettingValue | null][] = [];
  for (const key of keys) {
    if (updates[key] === null) {
      if (!defOf(key)) return { ok: false, key, why: "unknown setting" };
      planned.push([key, null]);
      continue;
    }
    const v = validate(key, updates[key]);
    if (!v.ok) return { ok: false, key, why: v.why };
    planned.push([key, v.value]);
  }
  const now = new Date().toISOString();
  db.transaction(() => {
    for (const [key, value] of planned) {
      if (value === null) db.prepare("DELETE FROM settings WHERE key = ?").run(key);
      else
        db.prepare(
          "INSERT INTO settings (key, value, updated_at, updated_by) VALUES (?,?,?,?) ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at, updated_by = excluded.updated_by",
        ).run(key, JSON.stringify(value), now, deviceId);
    }
  })();
  // Key names (and the rules length) only — never the text itself.
  const detail = planned
    .map(([k, v]) => (k === "rules.text" ? `${k}${v === null ? "=default" : `(${(v as string).length} chars)`}` : `${k}=${v === null ? "default" : v}`))
    .join(", ");
  logEvent(db, "settings.update", deviceId, detail);
  return { ok: true, changed: keys };
}

// ---- consumers -------------------------------------------------------------------

// Total size of the text appended to a session's system prompt (ADR 0031).
const MAX_RULES_CHARS = 16_000;

// The text appended to a session's system prompt, or null when there is none: the storage
// rules (if enabled and non-blank, ADR 0026) then every always-apply prompt that is global
// or scoped to [projectId] (ADR 0031). `names` is what the context sheet lists.
export function rulesForPrompt(db: DB, projectId: string | null): { text: string; names: string[] } | null {
  const parts: { name: string; text: string }[] = [];
  if (getSetting<boolean>(db, "rules.enabled")) {
    const text = getSetting<string>(db, "rules.text").trim();
    if (text) parts.push({ name: "Storage rules", text });
  }
  const packs = db
    .prepare("SELECT title, body FROM prompts WHERE always_apply = 1 AND (project_id IS NULL OR project_id = ?) ORDER BY created_at, id")
    .all(projectId) as { title: string; body: string }[];
  let total = parts.reduce((n, p) => n + p.text.length, 0);
  for (const p of packs) {
    const text = p.body.trim();
    if (!text) continue;
    if (total + text.length > MAX_RULES_CHARS) continue; // skip a pack that would push past the cap
    total += text.length;
    parts.push({ name: p.title, text });
  }
  if (parts.length === 0) return null;
  return { text: parts.map((p) => p.text).join("\n\n"), names: parts.map((p) => p.name) };
}

export const diskAlertPercent = (db: DB): number => getSetting<number>(db, "disk.alert_percent");
export const daemonDataAlertGb = (db: DB): number => getSetting<number>(db, "disk.daemon_data_alert_gb");

// Free bytes on the filesystem holding `path`, or null if it can't be read (fail open:
// a monitoring hiccup must not block work).
let statfsImpl: (p: string) => { free: number } | null = (p) => {
  try {
    const s = statfsSync(p);
    return { free: s.bavail * s.bsize };
  } catch {
    return null;
  }
};
/** Tests only. */
export function _setStatfsForTest(fn: ((p: string) => { free: number } | null) | null): void {
  statfsImpl = fn ?? ((p) => {
    try {
      const s = statfsSync(p);
      return { free: s.bavail * s.bsize };
    } catch {
      return null;
    }
  });
}

const GB = 1e9;
export function diskGuard(db: DB, path: string): { ok: true } | { ok: false; message: string } {
  const minGb = getSetting<number>(db, "disk.min_free_gb");
  if (minGb <= 0) return { ok: true };
  const s = statfsImpl(path);
  if (!s || s.free >= minGb * GB) return { ok: true };
  return {
    ok: false,
    message: `Only ${(s.free / GB).toFixed(1)} GB free where this lives (minimum ${minGb} GB) — free up space, or lower the limit in Settings → Session rules & storage`,
  };
}

export function registerSettingsRoutes(app: FastifyInstance, db: DB): void {
  app.get("/settings", async () => ({ settings: settingsView(db) }));

  app.put("/settings", { config: { rateLimit: { max: 30, timeWindow: "1 minute" } } }, async (req, reply) => {
    const values = ((req.body ?? {}) as { values?: unknown }).values;
    if (typeof values !== "object" || values === null || Array.isArray(values) || Object.keys(values).length === 0) {
      return reply.code(400).send({ error: "body must be {values: {key: value, …}}" });
    }
    const r = applySettings(db, values as Record<string, unknown>, (req as { device?: Device }).device?.id ?? null);
    if (!r.ok) return reply.code(400).send({ error: `${r.key}: ${r.why}` });
    return { settings: settingsView(db) };
  });
}
