# ADR 0016 — Model registry for every major provider, agent CLI presets, hand-off

**Status:** Accepted (2026-10-05). Roadmap phase 2 of [ADR 0015](0015-desktop-client.md).
Extends [ADR 0008](0008-native-engine.md) (native engine).

## Context

The goal is to send each piece of work to the model that fits it best, across
every major provider. ADR 0008 built the native engine, but only OpenAI was
wired up. `isNativeProvider` was hard-coded to `openai` and `google`, and a
non-Claude model only appeared if the operator hand-listed it in
`VIBE_GATEWAY_MODELS`. Separately, each vendor ships its own agent CLI (Codex,
Gemini CLI, Aider, …), and those can only run in a terminal.

## Decision

1. **Provider table (`providers.ts`).**
   - Providers: OpenAI, Google, xAI, Mistral, DeepSeek, Groq, OpenRouter (which
     covers the long tail) and Ollama (local, OpenAI-compatible).
   - All go through the Vercel AI SDK. The `@ai-sdk/*` packages are pinned to
     the majors built against `ai@6`'s provider spec v3.
   - A provider counts as *configured* only when its key env is set. For Ollama
     that's `VIBE_OLLAMA_URL`. Keys are read from the daemon's env file only.
2. **Namespaced model ids.** A discovered model's id is `provider:model`, split
   at the first colon (`openai:gpt-5`, `ollama:llama3:8b`).
   - `providerFor()` reads the prefix first, so routing needs no registry lookup
     and new models need no config.
   - Plain ids still resolve through the operator registry, then fall back to
     Anthropic.
   - The `anthropic` prefix is never native, so Claude always stays on the Agent
     SDK.
3. **Live discovery.** `GET /models` in direct mode merges three sources:
   - the live Anthropic list;
   - each configured provider's `/models` endpoint, filtered to chat models and
     cached for an hour (fails soft);
   - operator overrides.

   Gateway mode stays operator-authoritative, unchanged.
4. **Operator models file.** `VIBE_MODELS_FILE` (default
   `~/.config/vibe-daemon/models.json`) uses the same shape as
   `VIBE_GATEWAY_MODELS`, plus optional `price {in,out}` (USD per 1M tokens),
   `context` and `tags`.
   - Entries merge field by field, so a price-only entry annotates a discovered
     model.
   - Prices feed the cost meter (`priceFor`). OpenRouter's published prices are
     used automatically.
   - Tags appear in the picker as strength hints ("coding", "fast", "cheap").
5. **Agent CLI presets (`presets.ts`).**
   - `GET /presets` lists the table entries whose binary resolves in the
     operator's interactive bash. Detection runs there because these CLIs live
     on nvm/pipx PATHs the systemd env lacks.
   - `POST /sessions {kind:"terminal", preset}` creates a normal tmux shell and
     *types* the fixed command into it. Quitting the agent leaves a usable
     shell.
   - The client only ever sends an id. Unknown ids, non-string values, presets
     on `claude` sessions and uninstalled CLIs all get a 400.
6. **Hand-off (client).**
   - "Hand off to another model…" in the chat menu creates a new chat on the
     picked model.
   - Its `initialPrompt` is the recent transcript, capped at 12k characters with
     the oldest turns dropped first. Tool calls appear as one-line markers and
     tool output is left out.
   - The original session keeps running. Both engines honor `initial_prompt`.

## Consequences

- **Security** (`security.md` #11, #19): no new ingress and no keys on the wire.
  - A preset gives no capability a plain terminal session doesn't already have,
    and the command string never leaves the server.
  - Discovery only calls providers the operator configured, and only the
    providers' own model-list endpoints.
- An unconfigured provider no longer fails as a silent 401 with an empty key.
  The turn now ends with the chat error "provider X is not configured on the
  server".
- Native-engine limits from ADR 0008 still apply. Tier 2 tools are read-only;
  for real edits by a non-Claude model, use its agent CLI preset.
- ~~**Deferred:** per-task model profiles and automatic model suggestion.~~
  Done 2026-10-06, client only:
  - **Settings → Model per task** maps Plan / Implement / Review / Quick to a
    model, saved on the device (`TaskModelPrefs`).
  - When a prompt or template starts a new session, `suggestTask` reads its
    filled text by keywords (most specific first: review > plan > quick >
    implement; a short question counts as quick). The prompt-use screen
    preselects that task's model and shows "Suggested for X" with a Change
    button; the model goes out as the create call's `model`.
  - The plain New Claude button keeps the normal picker, since there's no prompt
    to read yet.

## Amendment (2026-10-08) — "Main model per task"

Settings → **Main model per task** (was "Model per task") picks the model of the *whole chat* a
prompt starts, per device. It is a different layer from the server's subagents
(`~/.claude/agents/`, delegation rule in `~/.claude/CLAUDE.md`), which pick helper models *inside*
a chat. The two stack. Unset rows show the suggested start (Plan/Review → Opus, Implement →
Sonnet, Quick → Haiku); nothing is saved until the user picks. See `docs/spikes/M16-spike-usage-and-subagents.md`.

