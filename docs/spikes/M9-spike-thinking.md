# M9 spike — extended thinking over the Agent SDK stream

**Question (gap analysis):** every mainstream harness shows the model's reasoning.
Can the daemon surface it, and what does the SDK actually emit?

**Script:** `vibe-daemon/src/spike-thinking.ts [enabled:summarized|adaptive:summarized|adaptive:omitted|default]`
— throwaway temp-dir cwd, SDK 0.3.291, model `claude-sonnet-5-5`, real Claude (a few
cents per run). Run 2026-10-07. Uses a hard counting question: an easy one (the
bat-and-ball puzzle) made *adaptive* thinking decide not to think at all.

## Results

| # | Question | Result |
|---|----------|--------|
| a | Default (no `thinking` option) | The model **does** think, but the assistant `thinking` block arrives **empty** (`thinking:""`, signature only) and the stream carries 2-3 empty `thinking_delta`s. Nothing to show. |
| b | `thinking:{type:'adaptive', display:'omitted'}` | Same as the default. |
| c | `thinking:{type:'adaptive', display:'summarized'}` | **Works.** `content_block_start@thinking`, ~50 `thinking_delta` events (≈500 chars total), one `signature_delta`, then a final assistant message whose `thinking` block holds the **summary** text. Stream order: thinking block → text block. |
| d | `thinking:{type:'enabled', budgetTokens:4000, display:'summarized'}` | Same shape as (c); a fixed budget, for older models. |
| e | Does adaptive always think? | **No** — trivial questions produce no thinking block at all. The UI must treat thinking as optional. |
| f | Cost | Not meaningfully different: ≈ $0.050 summarized vs ≈ $0.044 default on different answers (noise). |

## Consequences for the design

- To show reasoning the daemon must pass `thinking:{type:'adaptive', display:'summarized'}`
  (default on, `VIBE_SHOW_THINKING=0` restores the old behaviour).
- The text is a **summary**, not raw chain-of-thought — label it as such ("Thought").
- Forward `thinking_delta` live, then persist the final block as a `thinking` history
  row so a reattach replays it. Empty blocks produce no frame and no row.
- Re-run to check shapes after an SDK bump: the command above.
