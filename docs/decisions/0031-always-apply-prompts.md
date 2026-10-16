# ADR 0031 — Always-apply prompts extend session rules

**Status:** Accepted (2026-10-16). Amends [ADR 0026](0026-session-rules-and-settings.md) (that ADR stays
as written). Work: [proposal 61](../proposals/61-rule-packs-and-go-deeper.md).

## Context

ADR 0026 appends one global setting, the storage rules, to every session's system prompt. Guidance
such as Karpathy's guidelines or the Ambition pack lives in the prompt library but nobody applies
it automatically, and there is no way to scope rules to one project.

## Decision

1. **`prompts.always_apply`** (`INTEGER NOT NULL DEFAULT 0`, JSON boolean on the API). A flagged prompt is
   appended to the system prompt of every new session where `project_id IS NULL OR project_id = <session's project>`.
2. **`rulesForPrompt(db, projectId)`** returns `{ text, names } | null`: the storage rules first (only if
   `rules.enabled` and non-blank; name "Storage rules"), then flagged prompts by `created_at, id` (name =
   title), blank bodies skipped, joined with a blank line. Total capped at 16,000 characters; a pack that
   would pass the cap is skipped. `rules.enabled` remains the switch for the storage text only.
3. **No `{{vars}}`** in a flagged prompt: create and update return `400` (including a body-only edit of an
   already-flagged prompt). Nothing would fill them.
4. **Audit:** `prompt.always_apply` with `<id>=on|off` when the flag changes or a flagged prompt is created
   or deleted. Never the body (same rule as ADR 0026).
5. **Seeds:** `seed-karpathy` and the new `seed-ambition` are on by default. For databases that predate
   the column, the migration switches Karpathy on in the same branch that adds the column, so it happens
   once; a later opt-out sticks.
6. **Visibility:** the `context` frame keeps `rules: bool` and adds `ruleNames: string[]`; the context
   sheet lists them. Applied at session start only: running chats keep what they began with.
7. **Go deeper:** `POST /prompts/improve` takes an optional `mode` (`improve` default, `deeper`; anything
   else is `400`). Same lockdown as Improve (no tools, settings, MCP).

## Consequences

- Rules can now be edited, scoped and switched off from the prompt library, on the same bearer-gated
  surface as the rest of `/prompts`.
- Every session pays the tokens of its flagged prompts; the cap bounds it.
- A device with API access can change what every future session is told, as it already could via
  `PUT /settings`; both are audited.
