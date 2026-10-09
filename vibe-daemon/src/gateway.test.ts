// gateway.ts (ADR 0007) — gatewayEnv() opt-in behavior + listModels()/providerFor().
// Pure-ish functions driven by env; each test restores the env it touches. The live
// Anthropic Models API fetch is injected (fetchLive) so tests never hit the network.

import test from "node:test";
import assert from "node:assert/strict";
import { gatewayEnv, listModels, providerFor, type ModelInfo } from "./gateway.js";

function withEnv(vars: Record<string, string | undefined>, fn: () => void) {
  const saved: Record<string, string | undefined> = {};
  for (const k of Object.keys(vars)) saved[k] = process.env[k];
  for (const [k, v] of Object.entries(vars)) {
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
  try {
    fn();
  } finally {
    for (const [k, v] of Object.entries(saved)) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
  }
}

async function withEnvAsync(vars: Record<string, string | undefined>, fn: () => Promise<void>) {
  const saved: Record<string, string | undefined> = {};
  for (const k of Object.keys(vars)) saved[k] = process.env[k];
  for (const [k, v] of Object.entries(vars)) {
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
  try {
    await fn();
  } finally {
    for (const [k, v] of Object.entries(saved)) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
  }
}

// Fake live fetchers injected into listModels — no network, no CLI token read.
const liveNone = async (): Promise<ModelInfo[] | null> => null;
const liveOk = async (): Promise<ModelInfo[]> => [
  { id: "claude-opus-4-9", label: "Claude Opus 4.9", provider: "anthropic" },
  { id: "claude-opus-4-8", label: "Claude Opus 4.8", provider: "anthropic" },
];

test("gatewayEnv is undefined by default (no gateway → real Claude unchanged)", () => {
  withEnv({ VIBE_GATEWAY_URL: undefined }, () => {
    assert.equal(gatewayEnv(), undefined);
  });
});

test("gatewayEnv sets base URL + token and spreads process.env (keeps PATH)", () => {
  withEnv({ VIBE_GATEWAY_URL: "http://127.0.0.1:4000", VIBE_GATEWAY_TOKEN: "tok" }, () => {
    const env = gatewayEnv()!;
    assert.equal(env.ANTHROPIC_BASE_URL, "http://127.0.0.1:4000");
    assert.equal(env.ANTHROPIC_AUTH_TOKEN, "tok");
    // The critical pitfall: env REPLACES the subprocess env, so we must inherit PATH.
    assert.equal(env.PATH, process.env.PATH);
  });
});

test("gatewayEnv falls back to a default token when VIBE_GATEWAY_TOKEN is unset", () => {
  withEnv({ VIBE_GATEWAY_URL: "http://127.0.0.1:4000", VIBE_GATEWAY_TOKEN: undefined }, () => {
    assert.equal(gatewayEnv()!.ANTHROPIC_AUTH_TOKEN, "vibe-gateway");
  });
});

test("listModels falls back to the static Anthropic list (incl Opus 4.7) when the live API is unreachable", async () => {
  await withEnvAsync({ VIBE_GATEWAY_URL: undefined, VIBE_GATEWAY_MODELS: undefined }, async () => {
    const m = await listModels(liveNone);
    assert.ok(m.some((x) => x.id === "claude-opus-4-7"), "fallback must include claude-opus-4-7");
    assert.ok(m.every((x) => x.provider === "anthropic"));
  });
});

test("listModels uses the live Models API (auto-updates) in direct mode", async () => {
  await withEnvAsync({ VIBE_GATEWAY_URL: undefined, VIBE_GATEWAY_MODELS: undefined }, async () => {
    const m = await listModels(liveOk);
    assert.deepEqual(m.map((x) => x.id), ["claude-opus-4-9", "claude-opus-4-8"]);
  });
});

test("listModels merges operator overrides onto the live list (operator id wins, extras appended)", async () => {
  await withEnvAsync(
    {
      VIBE_GATEWAY_URL: undefined,
      VIBE_GATEWAY_MODELS: JSON.stringify([
        { id: "claude-opus-4-8", label: "My Opus" }, // override live entry's label
        { id: "gpt-4o", provider: "openai" }, // operator-only, appended
      ]),
    },
    async () => {
      const m = await listModels(liveOk);
      assert.deepEqual(m, [
        { id: "claude-opus-4-9", label: "Claude Opus 4.9", provider: "anthropic" },
        { id: "claude-opus-4-8", label: "My Opus", provider: "anthropic" }, // field-level merge keeps the live provider
        { id: "gpt-4o", label: "gpt-4o", provider: "openai" },
      ]);
    },
  );
});

test("listModels in gateway mode is operator-authoritative (never auto-fetches)", async () => {
  await withEnvAsync(
    {
      VIBE_GATEWAY_URL: "http://127.0.0.1:4000",
      VIBE_GATEWAY_MODELS: JSON.stringify([{ id: "gpt-4o", provider: "openai" }, { id: "claude-opus-4-8", label: "Opus" }]),
    },
    async () => {
      // liveOk would add entries if consulted; gateway mode must ignore it.
      const m = await listModels(liveOk);
      assert.deepEqual(m, [
        { id: "gpt-4o", label: "gpt-4o", provider: "openai" },
        { id: "claude-opus-4-8", label: "Opus", provider: undefined },
      ]);
    },
  );
});

test("listModels in gateway mode with no operator list degrades to a single default entry", async () => {
  await withEnvAsync({ VIBE_GATEWAY_URL: "http://127.0.0.1:4000", VIBE_GATEWAY_MODELS: undefined }, async () => {
    const m = await listModels(liveOk);
    assert.equal(m.length, 1);
    assert.equal(m[0].id, "default");
  });
});

test("providerFor routes by the operator registry; unknown/absent → anthropic", () => {
  withEnv({ VIBE_GATEWAY_MODELS: JSON.stringify([{ id: "gpt-4o", provider: "openai" }]) }, () => {
    assert.equal(providerFor("gpt-4o"), "openai");
    assert.equal(providerFor("claude-opus-4-7"), "anthropic"); // not in operator list → default
    assert.equal(providerFor(null), "anthropic");
  });
});

test("providerFor ignores malformed VIBE_GATEWAY_MODELS", () => {
  withEnv({ VIBE_GATEWAY_MODELS: "not json" }, () => {
    assert.equal(providerFor("gpt-4o"), "anthropic");
  });
});
