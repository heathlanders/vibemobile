# Prompting and token-saving guide

Practical rules for driving coding agents (Claude Code, Codex, Gemini CLI,
Aider, …) from VibeMobile. The app's **Improve prompt** action rewrites a draft
against the checklist in §1 (`vibe-daemon/src/prompt-improve.ts`). The
**Usage** page's tips (§3) check your real spend against the token rules.

## 1. Writing the prompt

| Do | Why |
|---|---|
| Lead with the goal, and say why if it isn't obvious | Agents pick better trade-offs when they know the purpose |
| Make success checkable: "tests in `auth.test.ts` pass", "`/health` returns 200" | Gives the agent a loop to run instead of guessing when it's done |
| Paste errors, commands and versions **verbatim** | Paraphrased errors send the agent to the wrong place |
| Name files and symbols you already know | Saves a search pass, which costs tokens and time |
| State scope: what to change, what to leave alone | Prevents "helpful" refactors and keeps diffs reviewable |
| For big work, ask for a plan first, then approve it | A wrong plan is far cheaper to fix than a wrong diff |
| Say "ask if unclear" | Stops the agent inventing an answer to an ambiguous request |
| Cut pleasantries and repetition | Every token of the prompt is re-read on every turn |

Save prompts that work to the library, with `{{vars}}` for the parts that
change. "Past prompts" in the library shows everything you've sent across all
sessions, so you can promote a good one.

### Ambition (Rieseberg)

Felix Rieseberg's [How to be more ambitious](https://felixrieseberg.com/how-to-be-more-ambitious-a-tutorial-for-humans-with-models/)
is applied two ways. The **Ambition (Rieseberg)** prompt is flagged *Apply to every session*, so it
rides along with Karpathy's guidelines in every new chat (ADR 0031). And **Improve → Go deeper**
rewrites a draft to ask what a top professional would do, from the rawest material, with which
methods, and what external evidence would show it is right. Ambition here means depth and
verification, never extra scope. The habit no tool can supply: give the model full context and
access, and take yourself out of the loop.

## 2. Picking the model (all providers)

- **Hard reasoning, architecture, gnarly bugs:** the biggest model you have
  (Opus-class, GPT-5-class, Gemini Pro).
- **Routine edits, tests, small refactors:** a mid-tier model (Sonnet-class).
  It's usually the best value.
- **Quick questions, renames, summaries:** a fast, cheap model (Haiku-class,
  Groq-hosted, a local Ollama model).
- **Second opinion:** use **Hand off to another model…** in the chat menu. The
  new session starts with the recent transcript, so a different model can
  review or continue the work.
- **Full agent on another vendor:** start its own CLI from the **Agent** menu
  (Codex, Gemini CLI, …). The native chat engine's non-Claude models only have
  read-only tools.

Add `tags` and `price` per model in `~/.config/vibe-daemon/models.json`, and
the picker shows them:

```json
[{ "id": "openai:gpt-5", "price": { "in": 1.25, "out": 10 }, "tags": ["reasoning", "coding"] },
 { "id": "groq:llama-3.3-70b-versatile", "tags": ["fast", "cheap"] }]
```

## 3. Saving tokens

Each turn re-sends the whole conversation, and prompt caching makes the
repeated part cheap. The rules follow from that:

1. **Keep one session per task, and keep it going.** Cache reads cost a fraction
   of fresh input. Starting many short sessions re-pays for the same context.
   (Tip: *low cache reuse*.)
2. **Don't churn the prefix mid-session.** Editing CLAUDE.md, switching models,
   or toggling tools invalidates the cache, so the next turn pays full price
   again. (Tip: *cache written more than read*.)
3. **Start a fresh session when the task changes**, or run `/compact`. Old
   context you no longer need still costs tokens on every turn. (Tip: *heavy
   context per turn*.)
4. **Keep CLAUDE.md lean.** It's loaded into every session. Link to docs instead
   of pasting them in.
5. **Send small edits to a cheap model.** (Tip: *expensive short turns*.)
6. **Point at files instead of pasting them.** The agent reads only what it
   needs.
7. **On a Max plan**, cost is shown as the API-equivalent. The real limits are
   the 5-hour and weekly meters in the chat header, and the same habits stretch
   them.
