// Model-agnostic gateway plumbing (ADR 0007). VibeMobile keeps the Agent SDK but
// can route it at a LOCAL Anthropic-compat gateway (LiteLLM / claude-code-router,
// 127.0.0.1 only) that translates the Anthropic Messages API onto any upstream
// provider/model. The daemon points the SDK's `claude` subprocess at the gateway
// via env; the per-session `model` string (options.model) selects the upstream.
//
// Opt-in + zero-risk default: when VIBE_GATEWAY_URL is unset, gatewayEnv() returns
// undefined, so options.env stays undefined and the SDK inherits process.env (real
// Claude via CLI login) exactly as before. Nothing here runs unless configured.
//
// Security (security.md): provider keys live ONLY in the gateway's own chmod-600
// config, never here and never on the wire. VIBE_GATEWAY_TOKEN is a loopback-only
// daemon↔gateway shared secret. The gateway binds localhost and is never
// tailscale-serve'd — `tailscale serve` stays the daemon's sole ingress (ADR 0005).

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { discoverNativeModels, isNativeProvider, splitModelId, cachedPrice, type Price } from "./providers.js";

export { isNativeProvider };

// Build the subprocess env for a gateway-routed Claude session, or undefined when
// no gateway is configured. CRITICAL: the SDK's `options.env` REPLACES the
// subprocess environment (it does NOT merge), so we spread process.env — otherwise
// the bundled CLI loses PATH/HOME and its login. Verified in the SDK .d.ts.
export function gatewayEnv(): NodeJS.ProcessEnv | undefined {
  const url = process.env.VIBE_GATEWAY_URL;
  if (!url) return undefined;
  return {
    ...process.env,
    ANTHROPIC_BASE_URL: url,
    // The CLI needs *some* token in base-URL mode; the gateway validates it.
    ANTHROPIC_AUTH_TOKEN: process.env.VIBE_GATEWAY_TOKEN ?? "vibe-gateway",
  };
}

// price (USD/1M tokens), context (tokens) and tags ("coding", "fast", "cheap", …)
// are optional, non-secret hints for the picker and the cost meter (ADR 0016).
export type ModelInfo = { id: string; label: string; provider?: string; price?: Price; context?: number; tags?: string[] };

// Last-resort default so GET /models always answers (gateway mode with no list, or
// the offline fallback below being empty is impossible, but keep the sentinel).
const DEFAULT_ENTRY: ModelInfo = { id: "default", label: "Default (Claude)", provider: "anthropic" };

// Offline/no-token fallback for the DIRECT-Anthropic picker. Used only when the
// live Models API can't be reached (no CLI login token, network blip). Kept small
// and current; the live list (fetchAnthropicModels) supersedes it whenever
// reachable, so this is a floor, not the source of truth.
const FALLBACK_ANTHROPIC: ModelInfo[] = [
  { id: "claude-opus-4-8", label: "Claude Opus 4.8", provider: "anthropic" },
  { id: "claude-opus-4-7", label: "Claude Opus 4.7", provider: "anthropic" },
  { id: "claude-sonnet-4-6", label: "Claude Sonnet 4.6", provider: "anthropic" },
  { id: "claude-haiku-4-5", label: "Claude Haiku 4.5", provider: "anthropic" },
];

// Operator-maintained, NON-SECRET model overrides: VIBE_GATEWAY_MODELS (JSON array
// of {id,label,provider,price?,context?,tags?}) plus the same shape in the models
// file (VIBE_MODELS_FILE, default ~/.config/vibe-daemon/models.json; file entries win
// on id clash). Their `provider` drives engine routing (providerFor); price/tags
// annotate any model, discovered ones included. Empty when unset/malformed. Never
// reads gateway secrets.
function parseModels(raw: string | undefined): ModelInfo[] {
  if (!raw) return [];
  try {
    const parsed = JSON.parse(raw);
    if (Array.isArray(parsed)) {
      return parsed
        .filter((m): m is ModelInfo => !!m && typeof m.id === "string")
        .map((m) => ({
          id: m.id,
          label: m.label ?? m.id,
          provider: m.provider,
          // Optional hints: only present when valid, so plain entries stay {id,label,provider}.
          ...(m.price && Number.isFinite(m.price.in) && Number.isFinite(m.price.out)
            ? { price: { in: m.price.in, out: m.price.out } }
            : {}),
          ...(Number.isFinite(m.context) ? { context: m.context } : {}),
          ...(Array.isArray(m.tags) ? { tags: m.tags.filter((t): t is string => typeof t === "string") } : {}),
        }));
    }
  } catch {
    // fall through to empty
  }
  return [];
}

function modelsFile(): string | undefined {
  const p = process.env.VIBE_MODELS_FILE ?? path.join(os.homedir(), ".config", "vibe-daemon", "models.json");
  try {
    return fs.readFileSync(p, "utf8");
  } catch {
    return undefined;
  }
}

function operatorModels(): ModelInfo[] {
  return mergeModels(parseModels(process.env.VIBE_GATEWAY_MODELS), parseModels(modelsFile()));
}

// The CLI-login OAuth access token (same credential usage.ts reuses). Read fresh so
// a token the CLI refreshed on disk is picked up. Never logged, never sent to the
// app. Absent/malformed → null (fail soft to the static fallback).
function readOAuthToken(): string | null {
  try {
    const p = path.join(os.homedir(), ".claude", ".credentials.json");
    const j = JSON.parse(fs.readFileSync(p, "utf8"));
    const t = j?.claudeAiOauth?.accessToken;
    return typeof t === "string" && t.length > 0 ? t : null;
  } catch {
    return null;
  }
}

// Live Anthropic model registry via GET /v1/models — auto-updates as Anthropic ships
// models, no code change needed. Authed with the CLI-login OAuth token (same pattern
// as usage.ts). Cached with a TTL and FAILS SOFT: any error → null so the picker
// falls back to FALLBACK_ANTHROPIC. Returns all entries as provider "anthropic".
const MODELS_URL = "https://api.anthropic.com/v1/models?limit=1000";
const MODELS_TTL_MS = 60 * 60_000; // models change rarely; poll gently
let modelCache: { at: number; data: ModelInfo[] } | null = null;
let lastModelAttempt = 0;

async function fetchAnthropicModels(): Promise<ModelInfo[] | null> {
  const now = Date.now();
  if (modelCache && now - modelCache.at < MODELS_TTL_MS) return modelCache.data;
  if (now - lastModelAttempt < MODELS_TTL_MS) return modelCache?.data ?? null; // back off on failure too
  lastModelAttempt = now;

  const token = readOAuthToken();
  if (!token) return modelCache?.data ?? null;

  try {
    const res = await fetch(MODELS_URL, {
      headers: {
        authorization: `Bearer ${token}`,
        "anthropic-beta": "oauth-2025-04-20",
        "anthropic-version": "2023-06-01",
      },
    });
    if (!res.ok) return modelCache?.data ?? null;
    const body: any = await res.json();
    const rows: any[] = Array.isArray(body?.data) ? body.data : [];
    const models = rows
      .filter((m) => m && typeof m.id === "string")
      .map((m) => ({ id: m.id as string, label: (m.display_name as string) || m.id, provider: "anthropic" }));
    if (!models.length) return modelCache?.data ?? null;
    modelCache = { at: now, data: models };
    return models;
  } catch {
    return modelCache?.data ?? null;
  }
}

// Merge the live/fallback base with operator overrides: an operator entry with the
// same id wins, keeping base fields it leaves unset (a price-only file entry still
// shows the discovered label); operator-only ids are appended. Preserves base order
// (newest-first from the API), operator extras last.
function mergeModels(base: ModelInfo[], operator: ModelInfo[]): ModelInfo[] {
  const byId = new Map(base.map((m) => [m.id, m]));
  for (const o of operator) {
    const b = byId.get(o.id);
    const defined = Object.fromEntries(Object.entries(o).filter(([, v]) => v !== undefined));
    byId.set(o.id, b ? { ...b, ...defined, label: o.label !== o.id ? o.label : b.label } : o);
  }
  return [...byId.values()];
}

// NON-SECRET model list for the picker (GET /models). Auto-updating: in the default
// (direct-Anthropic) mode it pulls the live Models API and merges operator overrides,
// so new Anthropic releases appear without a code or config change. In gateway mode
// the operator registry is authoritative (its providers drive routing and the Max
// OAuth token isn't the gateway's upstream), so we never auto-fetch there.
// Direct mode also lists every configured native provider's models (ADR 0016),
// discovered live and namespaced `provider:model`.
// `fetchLive`/`discover` are injectable for hermetic tests (no network). Never
// exposes secrets.
export async function listModels(
  fetchLive: () => Promise<ModelInfo[] | null> = fetchAnthropicModels,
  discover: () => Promise<ModelInfo[]> = discoverNativeModels,
): Promise<ModelInfo[]> {
  const operator = operatorModels();
  if (process.env.VIBE_GATEWAY_URL) {
    return operator.length ? operator : [DEFAULT_ENTRY];
  }
  const [live, native] = await Promise.all([fetchLive(), discover()]);
  return mergeModels([...(live ?? FALLBACK_ANTHROPIC), ...native], operator);
}

// Which engine serves a session (ADR 0008/0016). A `provider:model` id names its
// native provider directly; otherwise the operator registry decides; unknown/absent
// → "anthropic" (the Agent SDK path). Sync and routing-critical — reads only the id
// and operator config (live Anthropic models are always provider "anthropic").
export function providerFor(model: string | null | undefined): string {
  if (!model) return "anthropic";
  const split = splitModelId(model);
  if (split) return split.provider;
  return operatorModels().find((m) => m.id === model)?.provider ?? "anthropic";
}

// The provider-side model name: `openai:gpt-5` → `gpt-5`; other ids unchanged.
export function upstreamModel(model: string): string {
  return splitModelId(model)?.model ?? model;
}

// Cost-meter price for a model: operator config wins, then a discovered price
// (OpenRouter publishes them); undefined when unknown.
export function priceFor(model: string): Price | undefined {
  return operatorModels().find((m) => m.id === model)?.price ?? cachedPrice(model);
}
