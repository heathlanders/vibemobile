# ADR 0026 — Session rules and storage settings

**Status:** Accepted (2026-10-07). Builds on [ADR 0025](0025-storage-layout.md) (storage layout) and
[ADR 0019](0019-system-monitor.md) (disk alerts). Evidence: [M10 spike](../spikes/M10-spike-session-rules.md).

## Context

ADR 0025 moved caches, models and Docker to `/data` after `/` hit 94%. The rule "never create a
cache or data directory on `/`" is written into this repo's `CLAUDE.md`, so only sessions opened
in this repo see it. Prompts sent through the app into the other 11 projects carried no such
instruction (the M10 spike confirms sessions load project `CLAUDE.md` and nothing else). The
daemon also had no server-side settings at all — "env vars are the config" — and the disk
alert threshold was a constant.

## Decision

1. **A strictly whitelisted settings store** (`settings.ts`, table `settings`, JSON values):

   | Key | Type | Default | Meaning |
   |-----|------|---------|---------|
   | `rules.enabled` | bool | `true` | Append the rules to every session |
   | `rules.text` | text ≤ 4000 | storage rules (`DEFAULT_RULES`) | What is appended |
   | `disk.alert_percent` | int 50-99 | `90` | ADR 0019 alert threshold |
   | `disk.min_free_gb` | number 0-500 | `5` | Refuse new sessions/projects below this free space (0 = off) |
   | `disk.daemon_data_alert_gb` | number 0-1000 | `5` | Alert when the daemon's own data passes this (0 = off) |

   `GET /settings` / `PUT /settings {values:{key:value}}`. Unknown keys (own-key check — `__proto__`
   and `constructor` are not settings), wrong types and out-of-range values are `400` and change
   nothing (all-or-nothing); `null` resets a key. Audited as `settings.update` with key names
   and the rules **length**, never the text.
2. **Rules ride on the Claude Code preset:** `systemPrompt:{type:'preset',preset:'claude_code',append}`
   at every `ClaudeSession.start()`; the native engine appends the same text to its system prompt.
   Rules off or blank ⇒ no override at all (today's behaviour). A change applies to sessions
   started after it, not to ones already running.
3. **Disk threshold is configurable:** `computeAlerts(…, diskPercent)`; both `/system` and the
   background monitor read the setting.
4. **Free-space guard:** `POST /sessions` and `POST /projects` return `507` with a plain message
   when the filesystem holding the project (or the new project's root) has less than
   `disk.min_free_gb` free. An unreadable filesystem fails open. Audited `session.disk_guard`.
5. **Daemon data is visible and alertable** (`footprint.ts`): `GET /system` gains
   `footprint:[{label,bytes,truncated?}]` — Claude transcripts (`~/.claude/projects`), rewind
   backups (`~/.claude/file-history`, ADR 0023), the SQLite DB + WAL, and session worktrees —
   and `limits:{diskPercent,dataAlertGb}`. The total past `disk.daemon_data_alert_gb` raises the
   `daemon-data` alert (push via the ADR 0019 monitor). Pure-Node walk, never follows symlinks,
   capped at 500k entries (reported as a lower bound), cached 5 min. Measured 2026-10-07:
   transcripts 1.3 GB, rewind backups 31 MB, DB ≈ 28 MB — none has a retention cap of its own.
6. **App:** Settings → Server → *Session rules & storage*: the switch, a rules editor (with
   reset-to-default), the two numbers, and a link to live disk usage.

## Consequences

- **The rules are advice, not a lock.** A model can ignore them, and Bash cannot be contained.
  Real enforcement stays: the env vars every session inherits (`data-paths.env`), the Auto-mode
  file scope (security #7), and the free-space guard. The settings screen says so.
- **Security:** the API is bearer-gated like everything else. Editing the rules grants nothing a
  paired device cannot already do (it can send any prompt to a shell-capable session), but it
  shapes what *every* session is told, so it is audited and size-capped.
- The default text mentions only locations ADR 0025 has actually moved; update it when `~/.npm`
  or `CARGO_HOME` move.
- Mirrored CLI sessions (`vc`) and the one-shot titler/prompt-improve calls are not covered —
  they are not started with the daemon's options.
- Not done: per-project rules, rules history, a retention/cleanup action (the alert says to
  delete old sessions in the app; nothing deletes automatically).
