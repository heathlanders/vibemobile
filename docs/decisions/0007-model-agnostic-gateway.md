# ADR 0007 — Model-agnostic engine via a local Anthropic-compat gateway

**Status:** Accepted (2026-07-10)

## Context

The Claude engine ([ADR 0002](0002-hybrid-engine.md), `src/claude.ts`) drives the
Agent SDK (`@anthropic-ai/claude-agent-sdk` → the `claude` CLI headless). The M0
spike ([../spikes/M0-spike1-agent-sdk-auth.md](../spikes/M0-spike1-agent-sdk-auth.md))
confirmed it authenticates via the **CLI login, no API key**, and is hardwired to
Anthropic models. The user wants to pick **any** frontier model per session from
the chat UI — "like Claude chat is set up."

Options considered:
- **Native second engine** (Vercel AI SDK / per-provider SDKs) beside
  `ClaudeSession`. Rejected: it reimplements the streaming, tool-use loop,
  permission gate, AskUserQuestion, transcript persistence and resume — i.e.
  duplicates the security-critical core the Agent SDK gives us for free.
- **Gateway (chosen).**

## Decision

Keep the Agent SDK. Route it, when configured, at a **local Anthropic-compat
gateway** (LiteLLM / claude-code-router) bound to `127.0.0.1` that speaks the
Anthropic Messages API and translates to any upstream provider/model. The daemon
points the SDK subprocess at the gateway via `options.env`
(`ANTHROPIC_BASE_URL` + `ANTHROPIC_AUTH_TOKEN`) and selects the upstream with
`options.model`. A per-session `model` string (new `sessions.model` column) drives
it. Every existing capability — tool-use loop, permission gate, AskUserQuestion,
transcript persistence, resume — is unchanged because the gateway is transparent.

Verified in the SDK `.d.ts`: `Options.model?: string` exists, and `Options.env`
**replaces** the subprocess environment (does not merge) — so `gatewayEnv()`
(`src/gateway.ts`) spreads `process.env` or the CLI loses `PATH`/`HOME`/login.

## Consequences

- **Opt-in, zero-risk default.** With `VIBE_GATEWAY_URL` unset, `gatewayEnv()`
  returns `undefined` → `options.env` stays undefined → behaviour is byte-identical
  to real Claude via CLI login. The gateway is purely additive.
- **Model chosen at create, applied once in `start()`.** Keeps the
  `claude_session_id` resume contract clean. Switching model = a new session (the
  picker creates one). `Query.setModel()` exists for a future mid-session switch;
  deliberately unused for now.
- **Keys server-side only** (`security.md` #10). Provider keys live in the
  gateway's own `chmod 600` config outside the repo — never in the daemon, never on
  the wire, never in `GET /models`. `VIBE_GATEWAY_TOKEN` is a loopback-only
  daemon↔gateway secret.
- **Localhost only.** The gateway binds `127.0.0.1` and is **not**
  `tailscale serve`'d — `tailscale serve` stays the daemon's sole tailnet ingress
  ([ADR 0005](0005-tailscale-transport.md)).
- **Tool-use fidelity varies** for non-Claude models reached through Anthropic-API
  translation (GPT/Gemini may mishandle Claude tool schemas). Chat works broadly;
  agentic quality is model-dependent. The step-0 spike
  ([../spikes/M5-spike-gateway-model-swap.md](../spikes/M5-spike-gateway-model-swap.md))
  measures it and gates the whole approach.

## Config (operator)

Daemon env (systemd unit / `.env`):
- `VIBE_GATEWAY_URL` — e.g. `http://127.0.0.1:4000`. Unset = no gateway (default Claude).
- `VIBE_GATEWAY_TOKEN` — loopback shared secret the gateway validates.
- `VIBE_GATEWAY_MODELS` — JSON `[{id,label,provider}]` picker overrides (non-secret).

The gateway (LiteLLM/claude-code-router) runs as its own `127.0.0.1`-bound service;
provider API keys live in **its** `chmod 600` config, never in this repo.

### Picker list (auto-updating)

`GET /models` is auto-updating so new Anthropic releases need no code or config
change (`listModels()` in `gateway.ts`):

- **Direct mode** (no `VIBE_GATEWAY_URL`): the daemon fetches the live Anthropic
  Models API (`GET /v1/models`) using the same CLI-login OAuth token `usage.ts`
  reuses (`~/.claude/.credentials.json`, `Authorization: Bearer` +
  `anthropic-beta: oauth-2025-04-20`). Cached 1 h, **fail-soft** to a small static
  fallback (current Opus/Sonnet/Haiku, incl. Opus 4.7). `VIBE_GATEWAY_MODELS`
  becomes an *override/extend* layer: an entry with the same `id` replaces the
  live label/provider; a new `id` (e.g. a gateway model) is appended.
- **Gateway mode** (`VIBE_GATEWAY_URL` set): `VIBE_GATEWAY_MODELS` is authoritative
  (its `provider` values drive engine routing, and the Max OAuth token isn't the
  gateway's upstream) — no auto-fetch; single `default` entry when unset.

`providerFor()` (routing) reads only `VIBE_GATEWAY_MODELS` and stays synchronous;
live-fetched Anthropic models are always `provider: "anthropic"` (the default), so
they need no routing lookup.
