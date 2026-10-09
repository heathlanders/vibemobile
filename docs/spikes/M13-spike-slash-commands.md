# M13 spike — slash commands and skills over the Agent SDK

**Question (gap analysis):** Claude Code's skills and custom commands are a core feature of
mainstream harnesses. Can the daemon list what `/name` can run, and does sending `/name args`
as a normal chat message run it?

**Script:** `vibe-daemon/src/spike-commands.ts` — throwaway temp-dir cwd with
`.claude/commands/hello.md`, SDK 0.3.291, real Claude (a few cents). Run 2026-10-07.

## Results

| # | Question | Result |
|---|----------|--------|
| a | When can the list be read? | `Query.supportedCommands()` answers **before any user message** (≈ 0.7 s). The SDK only emits `system/init` once the first message is sent, so waiting for `init` would leave a fresh session's `/` picker empty. |
| b | Shape | `{name, description, argumentHint, builtin?}` (+ `aliases`). A project command shows up with its frontmatter description suffixed `(project)`. |
| c | What `builtin` means | **Claude Code's own** — but that includes its *bundled skills*: 55 rows in this project are flagged, 13 of them skills (`dataviz`, `update-config`, `code-review`, `simplify`, `fewer-permission-prompts`, `loop`, `schedule`, `claude-api`, `workflow-authoring`, `run`, `plugin-authoring`, `init`, `security-review`), the other 42 terminal/UX controls (`config`, `clear`, `compact`, `heapdump`, `color`, `effort`, `model`, `context`, …). |
| d | Telling them apart | `getContextUsage().skills.skillFrontmatter[].name` lists exactly the skills — a clean split. |
| e | Running one | A streamed user message `"/hello banana"` **runs the command**: the reply was `MAGIC-MARKER-42 banana`. No special API. |
| f | Name collisions | Per the SDK docs, when a built-in shares a name, `/name` runs the built-in. |
| g | Live changes | `system/commands_changed` carries the new list. |

## Consequences

- Offer: everything not flagged `builtin`, **plus** built-in-flagged rows that are skills.
  Withhold the terminal built-ins (some change settings or reset the session).
- Drop a non-built-in row whose name equals a withheld built-in (the picker would promise
  something `/name` doesn't run).
- Fetch at session start (commands + skills in parallel), keep fresh from `commands_changed`.
- Known gap: `verify`, `debug`, `batch`, `deep-research` and a few other prompt-style commands are
  flagged builtin but absent from the skills list, so they are withheld. An allow-list could
  add them; it would need upkeep as Claude Code changes.
- Sending needs no new daemon path: it is `pushUser("/name args")`.

## Re-run

```
cd vibe-daemon && npx tsx src/spike-commands.ts
```
