# M6 Spike — Native engine (Vercel AI SDK, non-Claude model + tool loop)

**Status:** ⏳ Pending live run (needs a real `OPENAI_API_KEY`)
**Code:** `vibe-daemon/src/spike-native.ts`
**Run:** `OPENAI_API_KEY=sk-… npm run spike:native -- <model-id>` (e.g. `gpt-4o`)

## Risk being killed

ADR 0008 runs non-Claude models **natively** (their own tool-calling + agent loop)
via the Vercel AI SDK (`ai` + `@ai-sdk/openai`), instead of translating them through
the Agent SDK (ADR 0007's gateway). Two go/no-go unknowns:
1. Does a real OpenAI model drive a native tool loop end-to-end (chat + a forced
   tool call + result + clean finish)?
2. Do the `streamText().fullStream` part shapes match what `native.ts` switches on
   (`text-delta`.text / `tool-call` / `tool-result` / `finish`.totalUsage)? The `ai`
   SDK API drifts across majors, so this must be confirmed against the pinned version.

## What the spike does

`streamText({ model: openai(id), prompt, tools: { list_dir }, stopWhen: stepCountIs(6) })`
with a prompt that forces the tool, iterates `fullStream`, and asserts it saw a
`tool-call`, a `tool-result`, and a `finish` with usage. PASS/FAIL + `process.exit`.
The tool's `execute` returns canned output — the spike proves the **loop**, not the fs.

## Pinned API (from the installed types, `ai@^6`)

- `streamText({ model, messages|prompt, system, tools, stopWhen, abortSignal })`.
- `stopWhen: stepCountIs(n)` bounds the agent loop.
- `tool({ description, inputSchema: z.object(...), execute })`.
- `fullStream` parts used: `text-delta` (`.text`), `tool-call` (`toolCallId/toolName/input`),
  `tool-result` (`toolCallId/output`), `tool-error`, `finish` (`finishReason/totalUsage`),
  `error`. `totalUsage` → `{ inputTokens, outputTokens }`.

These are the source of truth for `native.ts`'s stream switch; the fake-model unit
tests (`native.test.ts`) replay exactly these shapes.

## Result

_(fill in after the live run)_

```
[event] tool-call name=list_dir input={"path":"."}
[event] tool execute: list_dir(.)
[event] tool-result="a.txt\nb.txt\nsrc/"
[event] finish reason=stop usage={"inputTokens":…,"outputTokens":…}
[spike] PASS — native chat + tool loop work for this model
```

## Findings

_(fill in: did the model call the tool cleanly? any part-shape surprises vs the
pinned list above? per-model quirks — GPT vs Gemini tool-schema handling?)_

## Follow-ups

- Run the same shape per provider before enabling it in `VIBE_GATEWAY_MODELS`
  (Gemini via `@ai-sdk/google` is a future add).
- The daemon acceptance test: create an `openai` session, connect the WS, send a turn
  forcing a `read_file`, confirm `permission_request` → `permission{allow}` →
  `tool_result` → `result` over the real transport (the gated-tool security check).
