# 61 — Rule packs and "Go deeper"

**Status:** building (2026-10-16) · extends [ADR 0026](../decisions/0026-session-rules-and-settings.md) via [ADR 0031](../decisions/0031-always-apply-prompts.md)

## Problem

Felix Rieseberg's ["How to be more ambitious"](https://felixrieseberg.com/how-to-be-more-ambitious-a-tutorial-for-humans-with-models/)
and Karpathy's coding guidelines should shape every chat without being pasted by hand. Today the
prompt library is manual insert only (Karpathy is a seed nobody applies), and the only
auto-injected text is the one global storage-rules setting (ADR 0026). There are no per-project
rules.

## Approach

- Any prompt can be flagged **Apply to every session** (`prompts.always_apply`). Global
  (`project_id` null) or per project. Flagged bodies are appended to the system prompt of every
  new Claude or native session, after the storage rules.
- Two seeded packs, on by default: `seed-karpathy` (switched on once for existing DBs by the
  migration) and the new `seed-ambition`.
- The context sheet lists the names of the rules a chat started with.
- Composer and prompt-editor **Improve** offers a second mode, **Go deeper**: Felix's
  depth meta-prompt adapted to a coding agent. It rewrites a draft to ask for deeper methods, raw
  sources and external evidence, never more scope.

Tension: Karpathy's "simplicity first" versus ambition. The Ambition pack says ambition applies to
depth and verification, never to scope.

## Felix's rules and where each lands

| Rule | Where |
|---|---|
| Ask "what happens next?" (altitude) | Ambition pack |
| Aim for decisions, not outputs | Ambition pack |
| Pro-grade tools over approximations (real DB, tests, profilers) | Ambition pack |
| Start from the rawest material, not digests | Ambition pack |
| Challenge assumptions against data | Ambition pack |
| External validation, don't self-judge | Ambition pack (fits Karpathy #4) |
| Hard targets: treat as achievable, don't silently lower | Ambition pack |
| Verbs not nouns / interdisciplinary methods | Ambition pack (one line) and Go deeper |
| Depth-over-breadth meta-prompt | Go deeper mode |
| Give the model full context and access; remove yourself from the loop | Not automatable: a user habit. Noted here only. |

## Risks

- Everything flagged is sent on every session: capped at 16,000 characters total, packs past the
  cap are skipped. No `{{vars}}` allowed in a flagged prompt (nobody fills them).
- It shapes every session, so toggles are audited (`prompt.always_apply`, id and on/off, never the
  body), like ADR 0026.
- A bad pack degrades every chat; it is editable and can be switched off per prompt. Running
  chats keep what they started with.
- Ambition wording could pull scope up; the last line of the pack guards that.
