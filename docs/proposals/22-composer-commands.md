# 22 — Composer slash commands, prompt insert + `@file` mentions

Status: **shipped** (2a client-only; 2b adds one daemon read route → [ADR 0010](../decisions/0010-session-tree-read-surface.md))

## Problem

Everything the chat can do lives behind an app-bar icon or a long-press: changed
files, transcript copy, interrupt, the prompt library. On a phone that means
leaving the keyboard to reach a feature and coming back. Desktop coding clients
solved this with a slash palette in the input itself.

The prompt library was the worst case: using a saved prompt meant leaving the
chat entirely (dashboard → library → Use → *pick a target session*), so it could
not be used to add a turn to the session you were already in.

## UX

Typing `/` at the **start of a line** opens an inline suggestion list directly
above the composer (`ComposerSuggestions`) — not a modal, so the keyboard stays
up and density is preserved (DESIGN.md §1). Filter by typing; tap to run.

| Command | Does |
|---------|------|
| `/prompt <query>` | filters the prompt library live; tap → body inserted at the caret |
| `/files` | opens the changed-files sheet (proposal 20) |
| `/copy` | copies the transcript (proposal 06) |
| `/stop` | interrupts the running turn (proposal 09) — only listed while busy |

`/stop` and `/copy` reuse the existing controller/screen actions verbatim; no new
capability was added for any command.

**Prompts with `{{vars}}`** open a small sheet with one field per variable
(defaults from `vars_json`), then insert the filled text — reusing `extractVars`
and `fillTemplate` from `prompts/domain/prompt.dart`. The prompt library is
fetched once per chat, lazily, the first time `/prompt` is typed
(`GET /prompts?project_id=…`, so globals + this project's).

## `@file` mentions (phase 2b)

Typing `@` at a word boundary lists file names from the session's project and
inserts the picked path as literal `@lib/core/theme.dart ` text. Claude then reads
it with its own (gated) Read tool — **the daemon never resolves a mention**, so
the wire is unchanged and no new execution path exists.

Backed by `GET /sessions/:id/tree?q=&limit=` — a genuinely new read surface, so it
has its own [ADR 0010](../decisions/0010-session-tree-read-surface.md) and
`security.md` #13: session-scoped (not a project browser), names only, root-scoped
via `pathInRoots`, no shell-out, symlinks skipped, dotdirs/dep dirs excluded,
capped with a visible `truncated` flag, audited, rate-limited.

Client behaviour: one fetch per distinct `@` query; late answers to a stale query
are dropped. When the server flags `truncated`, the list ends with a "More matches
— keep typing" row rather than silently implying full coverage.

## Trigger rules (pure, unit-tested)

`chat/domain/composer_triggers.dart` → `detectSlash(text, caret)`:

- the `/` must start a line — `lib/core/theme.dart` and `https://x.dev/y` never
  trigger;
- a newline after the `/` ends the trigger;
- `query` splits into `command` (first word) and `argument` (the rest), so
  `/prompt code review` filters on `code review`;
- out-of-range/absent caret returns null.

`detectMention(text, caret)` mirrors it for `@`: the `@` must start a word (start
of text or after whitespace) so `me@example.com` never triggers, and any
whitespace ends the mention. A slash trigger under the caret wins over an earlier
`@`.

Pure so `flutter test` covers both without a device — same idiom as `extractVars`
and `sessionMatches`.

## Deviations from the plan (deliberate)

1. **Var-filling stays in the chat.** The plan said route to `PromptUseScreen`
   when a prompt has `{{vars}}`. That screen `pushReplacement`es into *another*
   session, which is wrong for "insert into the chat I'm in". A local sheet
   reusing the same template helpers is both smaller and correct.
2. **No separate command palette.** The plan listed a `showSearch`-based palette
   as a second entry point. The slash list *is* the palette, in the place the
   thumb already is; a second surface would duplicate it for no new capability.
3. **`@` handling landed in 2b, not 2a.** Shipping the mention trigger before the
   daemon route existed would have been speculative code; it went in with ADR 0010.

## Wire / architecture impact

**No WS change.** Slash commands are pure client. `@file` adds exactly one REST
read route (ADR 0010); inserted text — command output or mention — is an ordinary
composer edit that goes out on the existing `user` frame.

## Verification

- daemon `npm test` — 139 green, incl. 8 new in `project-tree.test.ts`
  (walk excludes `.git`/`node_modules`/symlink-escape, cap sets `truncated`,
  route audits `session.tree`, out-of-root ⇒ 403, unknown session ⇒ 404,
  unauthenticated ⇒ 401).
- `flutter test` — 66 green: 13 trigger cases (`composer_triggers_test.dart`),
  2 suggestion-list widget cases (`composer_overlay_test.dart`), 2 API cases
  (`project_tree_api_test.dart`).
- `flutter analyze` clean.
- On-device (pending): `/pr` filters to `/prompt`, a `{{var}}` prompt fills and
  inserts, `/files` opens the sheet, `/stop` appears only mid-turn, `@the` lists
  real project files and Claude reads the mentioned path.

## Touches

- client: `chat/domain/composer_triggers.dart` (new),
  `chat/presentation/composer_overlay.dart` (new),
  `chat/data/project_tree_api.dart` (new), `chat_screen.dart` (trigger state,
  suggestions, prompt insert + var sheet, mention fetch)
- daemon: `project-tree.ts` (new) + registration in `app.ts`
- tests: `composer_triggers_test.dart`, `composer_overlay_test.dart`,
  `project_tree_api_test.dart`, `project-tree.test.ts` (all new)
- docs: this file, ADR 0010, `security.md` #13, `session-rest.md`, proposals
  README, decisions README, docs-map, milestones
