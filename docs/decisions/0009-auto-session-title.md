# ADR 0009 — Auto-titled chat sessions

**Status:** Accepted (2026-07-24)

## Context

`sessions.title` was optional and nothing ever filled it: `POST /sessions` stored
whatever the client sent (nothing), and the Flutter label getter is
`title ?? id`. Every session therefore rendered as its raw server id
(`s_ab12cd34ef56`) — in the chat app bar, the project session list, the switcher,
the search results, and worst of all in the multi-chat grid, where up to six of
them ([proposal 19](../proposals/19-multi-chat-grid.md)) are visible at once and
indistinguishable.

Rename already existed (`PATCH /sessions/:id`, [proposal
12](../proposals/12-session-rename-tags.md)) but is manual; proposal 12 left
"auto-title from first prompt" open. This closes it.

## Decision

The daemon names a session from its **first turn**, in two phases
(`src/titler.ts`):

1. **Heuristic, synchronous.** On the first user turn — right after the user row
   is inserted — a pure function squashes the prompt to one line (drops fenced
   code, markdown link syntax, leading slash commands, control chars; cuts at the
   first sentence) and composes `"<project dir> · <body>"`, capped at 60 code
   points with word-boundary truncation. A raw id is therefore never displayed.
2. **LLM refine, asynchronous.** After the turn's `result`, one cheap
   single-turn model call replaces the heuristic with a real summary. Any
   failure — timeout, unknown model, junk output — leaves the heuristic standing.
   Refine is fire-and-forget and never on a turn's critical path.

Supporting decisions:

- **First turn only.** The guard is "exactly one `user` row in `messages`". A
  session is never re-titled as the chat drifts — a name that keeps moving under
  the user is worse than a slightly stale one.
- **The dir name is part of the title**, not just a subtitle, because the grid and
  the global switcher mix projects.
- **`sessions.title_auto` (new column) is the pin.** The auto-titler only ever
  writes `WHERE title IS NULL` (heuristic) or `WHERE title_auto = 1` (refine); a
  manual `PATCH {title}` sets `title_auto = 0`. So a user rename, and a title
  passed at create time, are permanent.
- **No backfill.** Existing rows default to `title_auto = 0` and have more than
  one user row, so both guards exclude them. No migration pass, no batch spend.
- **The refine runs in SDK isolation.** `settingSources: []` (no `~/.claude`
  settings, no project settings, no `CLAUDE.md`, no file-configured hooks),
  `tools: []`, `skills: []`, `plugins: []`, `mcpServers: {}`, `maxTurns: 1`, and a
  plain-string `systemPrompt` that replaces the `claude_code` preset. A throwaway
  summarizer must not inherit an agent's capabilities or a project's instructions.
  `permissionMode` stays `default` — never `bypassPermissions` (security.md).
- **The model's text is sanitized before it reaches the DB** (quote/period strip,
  reject empty, multi-line, or rambling output).
- **A new `title` WS frame** carries the change to an attached client, so an open
  chat updates in place. `attach()` re-sends the stored title because a
  create-with-prompt session ([proposal 15](../proposals/15-initial-prompt.md)) is
  primed *before* any socket exists.

Rejected: **LLM-only** (session shows a raw id for the 1–3 s the call takes);
**heuristic-only** (cheap, but the title is just the opening sentence, not what
the chat is about); **periodic re-titling** (name churn + N× the spend);
**reading the CLI's own JSONL summary** from `~/.claude/projects` (written lazily
on compaction — absent for a live session, verified empty on this host).

## Consequences

- **One extra cheap model call per session**, on `claude-haiku-4-5` by default,
  paid once at the first turn. Kill switches, all read per call:
  `VIBE_AUTO_TITLE=0` (feature off), `VIBE_AUTO_TITLE_LLM=0` (heuristic only),
  `VIBE_TITLE_MODEL`, `VIBE_TITLE_TIMEOUT_MS` (default 20 s, abort), and
  `VIBE_TITLE_MAX_INFLIGHT` (default 2 — over the cap, the heuristic stands).
- **Both engines hook it** ([ADR 0008](0008-native-engine.md)): `ClaudeSession`
  from `pushUser`/`result`/`attach`, `NativeSession` from
  `pushUser`/`reportCost`/`attach`. The logic lives once in `titler.ts`; each
  engine gains ~5 lines, matching the existing "3-line writers, cheaper than a
  base class" precedent in `native.ts`.
- **`ClaudeSession` reuses its injected `queryFn`** for the refine, so the whole
  path is covered by the existing fake-SDK test pattern — no subprocess, no spend
  in tests. `NativeSession` takes an optional `titleQueryFn` for the same reason;
  its test files set `VIBE_AUTO_TITLE_LLM=0` so an uninjected session can never
  spawn a real subprocess.
- **Native interrupt nit:** `NativeSession.interrupt()` emits `result` without
  going through `reportCost`, so an interrupted first turn defers the refine to
  the next completed turn. Harmless — the heuristic is already on screen.
- **The client keeps `label = title ?? id`.** The daemon owns titling; the app
  only renders the live `title` frame over its cached `Session.label`.
- **No transcript on disk (2026-10-06).** The refine call (and Improve prompt,
  ADR 0018) originally let the SDK persist a `.jsonl` under
  `~/.claude/projects/<project>/`, so `discover.ts` listed every title call as a
  session in the project's tab (34 of them on the box). Both now pass
  `persistSession: false` (verified against the real SDK: no transcript dir is
  created). `discover.ts` `isInternalTranscript` hides leftovers — exactly one
  real user turn that is the titler/improve prompt; one the user resumed and
  typed into stays listed — and `purgeInternalTranscriptRows` (daemon startup)
  dismisses + deletes already-registered `stale` rows. Transcript files are
  never deleted.
