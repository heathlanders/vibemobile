# M14 spike — branching a conversation (forkSession)

**Question (gap analysis):** can the daemon copy a conversation up to a chosen point into an
independent new session, using the message ids we already store?

**Script:** `vibe-daemon/src/spike-fork.ts` — throwaway temp-dir cwd, SDK 0.3.291, real Claude
(a few cents). Run 2026-10-07: two turns ("remember PINEAPPLE", "remember TURQUOISE"), fork, resume.

## Results

| # | Question | Result |
|---|----------|--------|
| a | Does the transcript keep the uuid we supplied on a streamed user message? | **Yes** — both `u1` and `u2` appear in `getSessionMessages()`. So `messages.sdk_uuid` (ADR 0023) is a valid fork anchor. |
| b | What does `getSessionMessages()` return? | `user` / `assistant` rows with `uuid`, in order (tool results are `user`-typed rows without one of our uuids). A turn therefore ends at the message just before the **next** of our uuids. |
| c | `forkSession(sid, {dir, upToMessageId, title})` | **Works.** Cutting at the assistant message before turn 2 produced a 2-message session. Resumed, it knew `PINEAPPLE` and not `TURQUOISE`. `dir` is the project directory the transcript lives under. |
| d | Original | Untouched (4 messages before and after, still remembers both). |
| e | Through the daemon on the real SDK | `POST /sessions/:id/fork {at:'after'}` on turn 1 → new `stale` session with `user,assistant,result` rows, resumes and answers `PINEAPPLE`; the original answers `PINEAPPLE, TURQUOISE`. |

## Consequences

- Cut points: **after** = up to the message before the next user turn (or a full copy for the
  last turn); **before** = up to the message before the chosen one (refused for the first).
- Our rows are copied to match; their `sdk_uuid` stays NULL — the fork's messages have fresh uuids
  and "forked sessions start without undo history", so rewind doesn't follow a fork.
- A worktree session isn't forked (the copy would share its checkout) — left for later.

## Re-run

```
cd vibe-daemon && npx tsx src/spike-fork.ts
```
