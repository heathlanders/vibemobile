# Proposal 04 — Session templates

## Why
One tap spawns a session pre-loaded with cwd + opening prompt ("review PR", "fix
failing tests"). Bridges prompt library ↔ sessions.

## Sketch
Template = a `prompts` row (already has `body`, `vars_json`, `project_id`) tagged
`template`. "Start from template" → `POST /sessions {kind:'claude', projectId}`
([session-rest.md](../protocols/session-rest.md)) → on init, daemon injects the
filled body as the first `user` turn.

## Impact
- **Wire:** none. Reuses session-rest create + first `user` frame.
- **Schema:** reuse `prompts`; add tag convention `template`. No new table.
- **Server:** optional `initialPrompt` field on `POST /sessions` so the first turn is
  atomic (vs client sending it post-connect).
- **Client:** template picker → var fill (reuse prompt-lib var UI) → create.

## Open
- `initialPrompt` server-side vs client sends after WS attach. Server-side =
  survives flaky first connect. Lean server-side.

## Status (2026-10-06)
Shipped, client only. The server half already existed: `POST /sessions`
`initialPrompt` (proposal 15) primes the first turn atomically.
- A template is any prompt tagged `template` (any case; `templatesOf`).
- In a project's sessions screen, the **Start from template** app-bar action
  lists global templates plus that project's. Picking one opens the prompt-use
  screen (var fill) with "new session in this project" preselected
  (`PromptUseScreen.initialTarget`).
- The new session uses the default model, with no picker.
- The desktop workspace sidebar has no template entry yet.
