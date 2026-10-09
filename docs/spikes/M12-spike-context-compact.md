# M12 spike — context-window usage and compaction over the Agent SDK

**Question (gap analysis):** every mainstream harness shows how full the context window is and
lets you compact. What does the SDK give the daemon, and does a streamed `/compact` work?

**Script:** `vibe-daemon/src/spike-compact.ts` — throwaway temp-dir cwd, SDK 0.3.291, model
`claude-sonnet-5-5`, real Claude (a few cents). Run 2026-10-07: two turns, then `/compact`.

## Results

| # | Question | Result |
|---|----------|--------|
| a | `Query.getContextUsage({detail:'summary'})` | **11-22 ms**, no per-category token-count API calls. `detail:'full'` took ~470 ms with somewhat different category numbers — use *summary* after every turn. |
| b | Response shape | **camelCase** — `totalTokens`, `maxTokens`, `rawMaxTokens`, `percentage`, `autoCompactThreshold`, `isAutoCompactEnabled`, `categories[{name,tokens,kind}]`. The `.d.ts` for the *message* type (`SDKContextUsage`) is snake_case; reading those names gave `undefined`. |
| c | Categories | `kind` is `used`\|`free`\|`buffer`\|`deferred`; only `used` rows occupy the window (System tools 8.8k, Skills 7.1k, Messages …). Classify on `kind`, never the English name (the SDK says so). |
| d | Window | This model reports a **1,000,000**-token window with auto-compaction at 967,000 — so a typical chat sits at 2-3%. |
| e | Streaming `/compact` as a user message | **Works.** The SDK emits `system/compact_boundary` `{trigger:'manual', pre_tokens:24261, post_tokens:2806, duration_ms:~9900, preserved_segment…}`, then **two `user` messages whose `content` is a plain string** (the continuation summary and `<local-command-stdout>Compacted </local-command-stdout>`), then a `result`. |
| f | After | The *Messages* category dropped 7,306 → 3,169 tokens; the next turn still answered correctly from the summary. |
| g | Auto compaction | Emits the same `compact_boundary` with `trigger:'auto'`. |

## Consequences

- Emit a `context` frame after each turn and on attach (cached + fresh when idle).
- `compact` = push the literal text `/compact` into the input stream — **not** stored as a user
  message (it is a command). Refuse while a turn runs.
- Persist `compact_boundary` as a `notice` history row so the compaction is visible after a
  reattach. This depends on the string-content fix from [proposal 37](../proposals/37-live-model-switch.md): without it the
  string `user` messages above would have killed the session.
- The window is big, so the useful signal is distance to the **auto-compaction point**, not the
  raw percentage — the app measures against `autoCompactThreshold` when it is known.
