# ADR 0018 — Prompt library v2: history, usage counts, "Improve prompt"

**Status:** Accepted (2026-10-05). Roadmap phase 4 of [ADR 0015](0015-desktop-client.md).

## Context

The library already had `{{var}}` templates, tags, project scoping, a "Use"
flow and `/prompt` in the composer (proposal 22). Three things were missing:

- finding prompts you've sent before;
- knowing which saved ones you actually use;
- help writing better prompts.

## Decision

1. **`GET /prompts/history?q=&limit=`** searches past user turns across every
   session. Identical texts collapse into one row, which carries
   `times`, `last_ts` and the project name. It uses an escaped `LIKE`, not
   FTS5: at personal scale there are about 800 user rows on the live DB, and
   FTS5's triggers and backfill aren't worth it yet. The client can promote a
   row to the library.
2. **`use_count` and `last_used_at`** columns are added through the existing
   idempotent `migrate()`. `POST /prompts/:id/use` increments them, and
   `GET /prompts?sort=used` sorts by them. The client counts a use from the
   Use screen and from composer `/prompt` inserts, fire-and-forget.
3. **`POST /prompts/improve {text}` → `{text}`** makes one Agent SDK call with
   the same lockdown as the auto-titler (ADR 0009):
   - `settingSources: []`, no tools, no MCP, no skills, `maxTurns: 1`, and
     never `bypassPermissions`;
   - its system prompt is the checklist from
     [`docs/prompting-guide.md`](../prompting-guide.md);
   - input is capped at 20k characters (413 above that), at most 2 calls run at
     once (429), and failures return 502;
   - the model is set by `VIBE_IMPROVE_MODEL` (default `claude-sonnet-4-6`).

   The client shows the original and the rewrite side by side. Nothing is
   applied without "Use improved". It's available in the prompt editor and as
   "Improve draft prompt" in the chat menu.

## Consequences

- **Security:** the improve call can only return text. It runs no tools,
  touches no files and doesn't load project config. The prompt text passes
  through the operator's own Claude login, the same as any chat. History is
  read-only over existing `messages` rows.
- Live-verified against the real SDK: a rewrite took about 7 seconds and kept
  the verbatim error message.
- **Deferred:** FTS5, if history grows past a few tens of thousands of rows.
