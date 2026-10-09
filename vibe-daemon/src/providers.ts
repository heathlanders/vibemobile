// Native provider table (ADR 0016, extends ADR 0008). Every non-Claude provider the
// native engine (native.ts) can drive, how to build its AI SDK model, and where to
// discover its model list. Claude stays on the Agent SDK and is not listed here.
//
// Security (security.md #11): keys come ONLY from the daemon's env (systemd unit);
// never on the wire, never in GET /models. A provider is "configured" only when its
// key env is set (Ollama: when VIBE_OLLAMA_URL is set), so nothing is probed or
// offered for a provider the operator hasn't opted into.
//
// Model ids: discovered models are namespaced `provider:model` (e.g. `openai:gpt-5`,
// `ollama:llama3:8b` — split at the FIRST colon), so routing (providerFor) stays a
// pure function of the id with no registry lookup.

import { createOpenAI } from "@ai-sdk/openai";
import { createGoogleGenerativeAI } from "@ai-sdk/google";
import { createXai } from "@ai-sdk/xai";
import { createMistral } from "@ai-sdk/mistral";
import { createDeepSeek } from "@ai-sdk/deepseek";
import { createGroq } from "@ai-sdk/groq";
import { createOpenAICompatible } from "@ai-sdk/openai-compatible";

export type Price = { in: number; out: number }; // USD per 1M tokens

export type DiscoveredModel = { id: string; label: string; provider: string; price?: Price; context?: number };

type ProviderSpec = {
  label: string;
  keyEnv?: string; // unset → keyless (Ollama)
  make: (model: string, key: string) => any;
  // OpenAI-style `GET …/models` → { data: [{ id }] }. Google uses its own shape.
  listUrl?: () => string;
};

const ollamaBase = () => (process.env.VIBE_OLLAMA_URL ?? "").replace(/\/+$/, "");

const PROVIDERS: Record<string, ProviderSpec> = {
  openai: {
    label: "OpenAI",
    keyEnv: "OPENAI_API_KEY",
    make: (m, apiKey) => createOpenAI({ apiKey })(m),
    listUrl: () => "https://api.openai.com/v1/models",
  },
  google: {
    label: "Google",
    keyEnv: "GOOGLE_GENERATIVE_AI_API_KEY",
    make: (m, apiKey) => createGoogleGenerativeAI({ apiKey })(m),
  },
  xai: {
    label: "xAI",
    keyEnv: "XAI_API_KEY",
    make: (m, apiKey) => createXai({ apiKey })(m),
    listUrl: () => "https://api.x.ai/v1/models",
  },
  mistral: {
    label: "Mistral",
    keyEnv: "MISTRAL_API_KEY",
    make: (m, apiKey) => createMistral({ apiKey })(m),
    listUrl: () => "https://api.mistral.ai/v1/models",
  },
  deepseek: {
    label: "DeepSeek",
    keyEnv: "DEEPSEEK_API_KEY",
    make: (m, apiKey) => createDeepSeek({ apiKey })(m),
    listUrl: () => "https://api.deepseek.com/models",
  },
  groq: {
    label: "Groq",
    keyEnv: "GROQ_API_KEY",
    make: (m, apiKey) => createGroq({ apiKey })(m),
    listUrl: () => "https://api.groq.com/openai/v1/models",
  },
  openrouter: {
    label: "OpenRouter",
    keyEnv: "OPENROUTER_API_KEY",
    make: (m, apiKey) => createOpenAICompatible({ name: "openrouter", baseURL: "https://openrouter.ai/api/v1", apiKey })(m),
    listUrl: () => "https://openrouter.ai/api/v1/models",
  },
  ollama: {
    label: "Ollama",
    make: (m) => createOpenAICompatible({ name: "ollama", baseURL: ollamaBase() })(m),
    listUrl: () => `${ollamaBase()}/models`,
  },
};

export function isNativeProvider(provider: string): boolean {
  return Object.hasOwn(PROVIDERS, provider);
}

function keyFor(provider: string): string | null {
  const spec = PROVIDERS[provider];
  if (!spec) return null;
  if (!spec.keyEnv) return ollamaBase() ? "" : null;
  return process.env[spec.keyEnv] || null;
}

export function isConfigured(provider: string): boolean {
  return keyFor(provider) !== null;
}

export function providerLabel(provider: string): string {
  return PROVIDERS[provider]?.label ?? provider;
}

// `openai:gpt-5` → { provider: "openai", model: "gpt-5" }; null when the prefix
// isn't a native provider (so `claude-…` ids and plain operator ids fall through).
export function splitModelId(id: string): { provider: string; model: string } | null {
  const i = id.indexOf(":");
  if (i <= 0) return null;
  const provider = id.slice(0, i);
  return isNativeProvider(provider) ? { provider, model: id.slice(i + 1) } : null;
}

// Build the AI SDK model for a native session. Throws when the provider has no key,
// surfacing as a chat `error` frame rather than a silent empty-key request.
export function nativeModel(provider: string, model: string): any {
  const key = keyFor(provider);
  if (key === null) throw new Error(`provider ${providerLabel(provider)} is not configured on the server`);
  return PROVIDERS[provider].make(model, key);
}

// Chat-capable filter for OpenAI-style lists, which also return embeddings, audio,
// image and moderation models the chat engine can't drive.
const NON_CHAT = /embed|tts|whisper|dall-e|image|audio|moderation|realtime|transcribe|speech|rerank|ocr|guard/i;

type Fetch = typeof fetch;
const LIST_TTL_MS = 60 * 60_000;
const listCache = new Map<string, { at: number; data: DiscoveredModel[] }>();

// One provider's model list, cached for an hour (failures too, so a bad key isn't
// retried on every picker open). Fails soft to the last good list or [].
async function discover(provider: string, fetchFn: Fetch): Promise<DiscoveredModel[]> {
  const cached = listCache.get(provider);
  if (cached && Date.now() - cached.at < LIST_TTL_MS) return cached.data;
  const key = keyFor(provider);
  let data: DiscoveredModel[] = cached?.data ?? [];
  try {
    if (provider === "google") {
      const res = await fetchFn("https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000", {
        headers: { "x-goog-api-key": key ?? "" },
      });
      if (res.ok) {
        const body: any = await res.json();
        data = (Array.isArray(body?.models) ? body.models : [])
          .filter((m: any) => typeof m?.name === "string" && (m.supportedGenerationMethods ?? []).includes("generateContent"))
          .map((m: any) => {
            const id = String(m.name).replace(/^models\//, "");
            return { id: `google:${id}`, label: m.displayName || id, provider, context: m.inputTokenLimit };
          });
      }
    } else {
      const url = PROVIDERS[provider].listUrl?.();
      if (url) {
        const res = await fetchFn(url, { headers: key ? { authorization: `Bearer ${key}` } : {} });
        if (res.ok) {
          const body: any = await res.json();
          data = (Array.isArray(body?.data) ? body.data : [])
            .filter((m: any) => typeof m?.id === "string" && !NON_CHAT.test(m.id))
            .map((m: any) => ({
              id: `${provider}:${m.id}`,
              label: m.name || m.id,
              provider,
              price: openRouterPrice(m.pricing),
              context: typeof m.context_length === "number" ? m.context_length : undefined,
            }));
        }
      }
    }
  } catch {
    /* network / parse error → keep the previous list */
  }
  listCache.set(provider, { at: Date.now(), data });
  return data;
}

// OpenRouter lists USD-per-token strings; convert to per-1M. Other providers → undefined.
function openRouterPrice(p: any): Price | undefined {
  const i = Number(p?.prompt), o = Number(p?.completion);
  return Number.isFinite(i) && Number.isFinite(o) && (i > 0 || o > 0) ? { in: i * 1e6, out: o * 1e6 } : undefined;
}

// Every configured provider's models. `fetchFn` is injectable for hermetic tests.
export async function discoverNativeModels(fetchFn: Fetch = fetch): Promise<DiscoveredModel[]> {
  const configured = Object.keys(PROVIDERS).filter(isConfigured);
  const lists = await Promise.all(configured.map((p) => discover(p, fetchFn)));
  return lists.flat();
}

// Price from the last discovery of [id], if its provider publishes one.
export function cachedPrice(id: string): Price | undefined {
  for (const { data } of listCache.values()) {
    const hit = data.find((m) => m.id === id);
    if (hit) return hit.price;
  }
  return undefined;
}

export function clearDiscoveryCache(): void {
  listCache.clear();
}
