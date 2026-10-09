# M10 spike — injecting rules into every session's system prompt

**Question (ADR 0026):** the storage rules (ADR 0025) live in this repo's `CLAUDE.md`, so only
sessions opened in *this* repo see them. Can the daemon make every prompt sent through
VibeMobile follow them — in any project — without breaking each project's own `CLAUDE.md`?

**Script:** `vibe-daemon/src/spike-session-rules.ts [default|append]` — throwaway temp-dir cwd
containing a `CLAUDE.md` that demands a marker word; SDK 0.3.291, real Claude (a few cents).
Run 2026-10-07. Also checked through `ClaudeSession` end to end (see below).

## Results

| # | Question | Result |
|---|----------|--------|
| a | Does a daemon-started session (no `systemPrompt`, no `settingSources`, i.e. today) load the project's `CLAUDE.md`? | **Yes.** The reply carried the CLAUDE.md marker. |
| b | `systemPrompt:{type:'preset',preset:'claude_code',append:<rules>}` | **Works.** The appended marker was obeyed **and** the project's CLAUDE.md marker still appeared — the preset keeps the Claude Code prompt, so project memory loads alongside. |
| c | Through `ClaudeSession` with rules from the settings store | Custom rules obeyed with CLAUDE.md intact; with `rules.enabled=false` only CLAUDE.md applies (identical to before). |
| d | Does the *shipped default text* change behaviour? | Asked "where should I create an npm cache directory?" the model answered `/data/cache/npm`. |

## Findings about the current state (2026-10-07)

- Environment enforcement already works: the user unit `vibe-daemon` loads
  `~/.config/data-paths.env`, and the daemon, the SDK subprocesses it spawns, and tmux
  terminals all carry `GRADLE_USER_HOME`, `PUB_CACHE`, `ANDROID_HOME`, `VIBE_PROJECT_ROOTS`, ….
- Instruction coverage did **not**: 11 other projects have a `CLAUDE.md` without the rules and
  there is no `~/.claude/CLAUDE.md`, so a prompt sent into any of them carried no storage rule.

## Consequences

- The daemon appends the rules to every session (`claude.ts` `start()`), and to native-engine
  sessions' system prompt (`native.ts`); the text and an on/off switch are settings (ADR 0026).
- The rules are **advice**. Enforcement stays where it is: inherited env vars, Auto-mode file
  scope, and the new free-space guard.

## Re-run

```
cd vibe-daemon
npx tsx src/spike-session-rules.ts default
npx tsx src/spike-session-rules.ts append
```
