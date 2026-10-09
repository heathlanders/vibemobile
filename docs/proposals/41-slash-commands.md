# 41 — Skills and slash commands in the composer

**Status:** implemented (daemon + app + tests 2026-10-07; on-device check pending)

Typing `/` in the chat now also lists the session's **skills and project/plugin commands**
(`/simplify`, `/code-review`, `/loop`, your own `.claude/commands/*`). Evidence:
[M13 spike](../spikes/M13-spike-slash-commands.md).

- **Wire** ([claude-ws.md](../protocols/claude-ws.md)): server → `commands`
  `{commands:[{name, description, hint}]}`, sent at session start (before any message), on
  attach (cached) and whenever the SDK reports `commands_changed`. Sending one is just a
  `user` frame starting with `/` — no new client frame. Claude engine only.
- **Daemon:** `commands.ts` (`publicCommands`, `skillNamesFrom`): offers non-built-in rows plus
  built-in rows that are skills; withholds terminal built-ins (`/config`, `/clear`, `/heapdump`…);
  drops a row whose name a withheld built-in would shadow; validates names, clips text, caps at
  200. `ClaudeSession.loadCommands` reads `supportedCommands()` and the skills list in parallel
  (guarded against a double read; best-effort — a failure sends nothing).
- **App:** `SlashCommandInfo` / `matchCommands` (`chat/domain/slash_command.dart`: prefix matches
  before substring/description matches, excludes names the app handles locally). The composer's
  suggestion list shows them under the local `/prompt /files /mode /copy /stop`, with the
  argument hint and description; picking one inserts `/name ` so you can add arguments. Hidden
  once you've typed a space, and for a mirrored CLI session.
- **Security:** nothing new is reachable — a paired device can already send any prompt, and a
  skill runs through the same permission gate and file scope as anything else. The list is
  display data; the daemon never executes a name it was handed.

Out of scope: argument pickers, showing which skills are built in vs yours, the withheld
prompt-style built-ins (`/verify`, `/debug`, `/batch`, `/deep-research`), running commands on a
native-engine session.

Tests: `vibe-daemon/src/commands.test.ts`, `app/test/slash_command_test.dart`.
