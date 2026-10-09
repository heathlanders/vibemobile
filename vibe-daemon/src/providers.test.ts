// providers.ts (ADR 0016) — provider table, `provider:model` routing, live model
// discovery (fake fetch, no network), registry merge + pricing via gateway.ts.

import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  clearDiscoveryCache,
  discoverNativeModels,
  isConfigured,
  isNativeProvider,
  nativeModel,
  splitModelId,
} from "./providers.js";
import { listModels, priceFor, providerFor, upstreamModel } from "./gateway.js";

const KEYS = [
  "OPENAI_API_KEY",
  "GOOGLE_GENERATIVE_AI_API_KEY",
  "XAI_API_KEY",
  "MISTRAL_API_KEY",
  "DEEPSEEK_API_KEY",
  "GROQ_API_KEY",
  "OPENROUTER_API_KEY",
  "VIBE_OLLAMA_URL",
  "VIBE_MODELS_FILE",
  "VIBE_GATEWAY_URL",
  "VIBE_GATEWAY_MODELS",
];

// Run with ONLY [vars] set among the provider/registry env; restore afterwards.
async function withOnly(vars: Record<string, string>, fn: () => Promise<void> | void) {
  const saved = Object.fromEntries(KEYS.map((k) => [k, process.env[k]]));
  for (const k of KEYS) delete process.env[k];
  process.env.VIBE_MODELS_FILE = "/nonexistent/models.json"; // never read the operator's real file
  Object.assign(process.env, vars);
  clearDiscoveryCache();
  try {
    await fn();
  } finally {
    for (const [k, v] of Object.entries(saved)) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
    clearDiscoveryCache();
  }
}

function fakeFetch(routes: Record<string, unknown>, seen: string[] = []) {
  return (async (url: string) => {
    seen.push(url);
    const body = routes[url];
    return { ok: body !== undefined, json: async () => body } as Response;
  }) as unknown as typeof fetch;
}

test("splitModelId: first colon splits, only for native providers", () => {
  assert.deepEqual(splitModelId("openai:gpt-5"), { provider: "openai", model: "gpt-5" });
  assert.deepEqual(splitModelId("ollama:llama3:8b"), { provider: "ollama", model: "llama3:8b" });
  assert.deepEqual(splitModelId("openrouter:meta/llama-4"), { provider: "openrouter", model: "meta/llama-4" });
  assert.equal(splitModelId("claude-opus-4-8"), null);
  assert.equal(splitModelId("anthropic:claude"), null); // Claude never routes native
  assert.equal(splitModelId("evil:thing"), null);
});

test("providerFor: prefix wins, else operator registry, else anthropic", async () => {
  await withOnly({ VIBE_GATEWAY_MODELS: JSON.stringify([{ id: "gpt-4o", provider: "openai" }]) }, () => {
    assert.equal(providerFor("xai:grok-4"), "xai");
    assert.equal(providerFor("gpt-4o"), "openai");
    assert.equal(providerFor("claude-sonnet-4-6"), "anthropic");
    assert.equal(upstreamModel("google:gemini-2.5-pro"), "gemini-2.5-pro");
    assert.equal(upstreamModel("gpt-4o"), "gpt-4o");
  });
  for (const p of ["openai", "google", "xai", "mistral", "deepseek", "groq", "openrouter", "ollama"]) {
    assert.equal(isNativeProvider(p), true, p);
  }
  assert.equal(isNativeProvider("anthropic"), false);
});

test("a provider is configured only by its key env (Ollama: by its URL)", async () => {
  await withOnly({ XAI_API_KEY: "k" }, () => {
    assert.equal(isConfigured("xai"), true);
    assert.equal(isConfigured("openai"), false);
    assert.equal(isConfigured("ollama"), false);
    assert.throws(() => nativeModel("openai", "gpt-5"), /not configured/);
    assert.ok(nativeModel("xai", "grok-4"));
  });
  await withOnly({ VIBE_OLLAMA_URL: "http://127.0.0.1:11434/v1" }, () => {
    assert.equal(isConfigured("ollama"), true);
  });
});

test("discovery: configured providers only, chat models only, namespaced ids, cached", async () => {
  await withOnly({ OPENAI_API_KEY: "k1", GOOGLE_GENERATIVE_AI_API_KEY: "k2", OPENROUTER_API_KEY: "k3" }, async () => {
    const seen: string[] = [];
    const f = fakeFetch(
      {
        "https://api.openai.com/v1/models": { data: [{ id: "gpt-5" }, { id: "text-embedding-3-large" }, { id: "tts-1" }] },
        "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000": {
          models: [
            { name: "models/gemini-2.5-pro", displayName: "Gemini 2.5 Pro", inputTokenLimit: 1048576, supportedGenerationMethods: ["generateContent"] },
            { name: "models/embedding-001", supportedGenerationMethods: ["embedContent"] },
          ],
        },
        "https://openrouter.ai/api/v1/models": {
          data: [{ id: "deepseek/deepseek-r1", name: "DeepSeek R1", context_length: 64000, pricing: { prompt: "0.00000055", completion: "0.00000219" } }],
        },
      },
      seen,
    );
    const models = await discoverNativeModels(f);
    assert.deepEqual(
      models.map((m) => m.id),
      ["openai:gpt-5", "google:gemini-2.5-pro", "openrouter:deepseek/deepseek-r1"],
    );
    const g = models.find((m) => m.provider === "google")!;
    assert.equal(g.label, "Gemini 2.5 Pro");
    assert.equal(g.context, 1048576);
    const r = models.find((m) => m.provider === "openrouter")!;
    assert.ok(Math.abs(r.price!.in - 0.55) < 1e-9 && Math.abs(r.price!.out - 2.19) < 1e-9);
    assert.equal(seen.length, 3); // no xai/mistral/… probes without keys

    await discoverNativeModels(f);
    assert.equal(seen.length, 3, "second call served from cache");
    assert.ok(Math.abs(priceFor("openrouter:deepseek/deepseek-r1")!.in - 0.55) < 1e-9, "discovered price feeds the meter");
  });
});

test("discovery fails soft: a dead endpoint yields no models, not an error", async () => {
  await withOnly({ MISTRAL_API_KEY: "k" }, async () => {
    const boom = (async () => {
      throw new Error("ECONNREFUSED");
    }) as unknown as typeof fetch;
    assert.deepEqual(await discoverNativeModels(boom), []);
  });
});

test("listModels appends discovered models; the models file annotates them", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "vibe-models-"));
  const file = path.join(dir, "models.json");
  fs.writeFileSync(file, JSON.stringify([{ id: "openai:gpt-5", price: { in: 1.25, out: 10 }, tags: ["coding", "reasoning"] }]));
  await withOnly({}, async () => {
    process.env.VIBE_MODELS_FILE = file;
    const live = async () => [{ id: "claude-opus-4-8", label: "Claude Opus 4.8", provider: "anthropic" }];
    const discover = async () => [{ id: "openai:gpt-5", label: "gpt-5", provider: "openai" }];
    const m = await listModels(live, discover);
    assert.deepEqual(m, [
      { id: "claude-opus-4-8", label: "Claude Opus 4.8", provider: "anthropic" },
      { id: "openai:gpt-5", label: "gpt-5", provider: "openai", price: { in: 1.25, out: 10 }, tags: ["coding", "reasoning"] },
    ]);
    assert.deepEqual(priceFor("openai:gpt-5"), { in: 1.25, out: 10 });
  });
  fs.rmSync(dir, { recursive: true });
});
