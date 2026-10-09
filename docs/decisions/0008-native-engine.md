# ADR 0008 — Native multi-provider engine (Vercel AI SDK)

**Status:** Accepted (2026-07-13)

## Context

[ADR 0007](0007-model-agnostic-gateway.md) makes non-Claude models reachable by
routing the Agent SDK through a translating gateway — but that runs GPT/Gemini
*inside Claude Code's harness* (its tools, its system prompt) via Anthropic→provider
translation, and tool-use fidelity through that translation is model-dependent. The
user wants non-Claude models running **as themselves**: their own native
tool-calling and agent loop.

## Decision

Add a second engine, `NativeSession` (`src/native.ts`), over the **Vercel AI SDK**
(`ai` + `@ai-sdk/openai`, later `@ai-sdk/google`) — one unified engine with a
per-provider adapter, **not** an engine per provider. It emits the **same
`claude-ws.md` frames** as `ClaudeSession`, so the Flutter UI, the WS handler,
persistence, and the reaper are unchanged. The engine is chosen per session by the
model's `provider` (`session-ws.getOrStart` → `providerFor`/`isNativeProvider`,
`src/gateway.ts`): `openai`/`google` → native; everything else → the Agent SDK.

Both engines drive tool approvals through **one shared `PermissionGate`**
(`src/permission-gate.ts`, extracted verbatim from `claude.ts` — reuse, not
reimplementation). Every native tool's `execute()` calls `gate.request()` first;
paths are re-scoped with `pathInRoots` (security.md #7). Capability is a dial
(`VIBE_NATIVE_TIER`): 1 chat, 2 read-only tools (default), 3 write/bash (not built —
gates on a security review).

Rejected: a separate engine per provider (N tool loops, N gates, N SDK-churn
surfaces) — the unified engine gives native per-provider fidelity with one
security-critical loop to maintain.

## Consequences

- **Two engines, one wire.** `EngineSession` (`src/engine.ts`) is the shared surface
  both implement; the registry holds `EngineSession`. Adding a provider = an adapter
  in the `providerFactory`, not a new engine.
- **The gate is the load-bearing reuse.** A native tool that skips `gate.request()`
  is a shell-over-network hole. It's the *same* gate as Claude (auto-allow default,
  timeout-deny, no-client-deny, per-decision `events` audit), guarded by the existing
  `claude.test.ts` gate tests as the extraction regression.
- **Stateless / resume.** Native models are stateless HTTP — no `claude_session_id`;
  the transcript IS the state (in-memory `ModelMessage[]` + the `messages` table).
  Native `init` omits `claudeSessionId`. Resume = replay the transcript into
  `streamText` each turn. Replaying the full transcript grows cost on long
  sessions (same as Claude effectively).
  - **Tool rows on resume** (2026-10-06, the "summarize" option). A live session
    keeps the SDK's real tool messages in memory. After a restart or evict,
    `replayHistory` turns each persisted tool row into a one-line note,
    `[tool <name> <input ≤200 chars> → <result ≤300 chars | error: …>]`, folded
    into the assistant turn it belongs to.
  - The rebuilt conversation strictly alternates user/assistant, so it's valid
    for every provider. Exact tool-call/tool-result replay was rejected: the
    pairing rules differ per provider and would need a live-key spike for each.
  - Tested with the fake `streamTextFn` only; no live provider run.
- **Keys server-side only** (security.md #11): `OPENAI_API_KEY` etc. from systemd env,
  never on the wire, never in `/models`.
- **Fidelity is per-model** and gated by the M6 spike
  ([../spikes/M6-spike-native-engine.md](../spikes/M6-spike-native-engine.md)); run
  the live tool round-trip per provider before enabling it in `VIBE_GATEWAY_MODELS`.
- Relationship: extends the hybrid-engine idea (ADR 0002) to N engines; complementary
  to ADR 0007 (0007 = translated via gateway; 0008 = native). The gateway stays as an
  optional fallback for models without a native adapter.
