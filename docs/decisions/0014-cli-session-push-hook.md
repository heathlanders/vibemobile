# ADR 0014 — Push for CLI sessions via a Claude Code hook

**Status:** Accepted (2026-09-27). Closes the follow-up in ADR 0013 (Consequences).

## Context

ADR 0013 pushes when an **in-daemon** session needs the user. A `claude` CLI
running on the server outside the daemon (ADR 0012 — VS Code terminal, `vc`)
never reaches `claude.ts`, so its permission prompts and questions sit in the
TUI unseen. Claude Code exposes them through its `Notification` hook
(`notification_type`: `permission_prompt`, `elicitation_dialog`, `idle_prompt`, …).

Two constraints shape the design:

1. **"From localhost" is not authentication here.** `tailscale serve` proxies
   phone traffic to `127.0.0.1:8787`, so a route on the main port can't tell the
   hook from a paired phone — or from any tailnet peer that reaches the proxy.
2. **The Agent SDK loads `~/.claude/settings.json` hooks by default**, so the
   daemon's own sessions fire the hook too, and they already push themselves.

## Decision

1. **A separate Unix socket** `~/.config/vibe-daemon/hook.sock`
   (`$VIBE_HOOK_SOCKET`), created mode **600** (umask set before bind, so no
   window where it is wider). Only the operator's own processes can connect;
   `tailscale serve` can't reach it. No token to manage. Stale socket removed on
   start.
2. **One user-level hook** in `~/.claude/settings.json`, applying to every CLI
   session on the box (not just `vc`):
   ```json
   "hooks": { "Notification": [{ "matcher": "permission_prompt|elicitation_dialog|idle_prompt",
     "hooks": [{ "type": "command", "async": true, "timeout": 5,
       "command": "curl -s -m 3 --unix-socket \"$HOME/.config/vibe-daemon/hook.sock\" --data-binary @- http://vibe/hook >/dev/null 2>&1 || true" }] }] }
   ```
   `async` + `|| true`: a stopped daemon never slows or breaks the CLI.
3. **Notify only.** `permission_prompt` → `cli_permission`, `elicitation_dialog`
   → `cli_question`, `idle_prompt` → `cli_waiting`; other types are ignored.
   Same content-free `{type, sessionId}` FCM payload as ADR 0013. The phone shows
   a tap-to-open notification with no Allow/Deny — the answer happens in the
   session's terminal (the app's Terminal view for a `vc` session). An
   actionable CLI approval (a blocking `PermissionRequest` hook) would be a new
   remote-approval path and needs its own ADR.
4. **No `Stop` hook.** It fires every turn and would buzz the phone while the
   operator is at the PC. `idle_prompt` (~60 s with no reply) is the "walked
   away" signal.
5. **Only real external CLIs push.** The hook's `session_id` must be a live
   entry in `runningCliSessions()` (pid + `procStart` check, daemon children
   excluded — ADR 0012). A session the daemon runs (`registry`) or a phone is
   mirroring (`Mirror.watching`) is skipped. A CLI session with no row yet is
   discovered on the spot when its `cwd` is a catalogued project; otherwise
   nothing is sent.

## Consequences

- Any process running as the operator can make the daemon push "needs
  approval" for a live CLI session. That is no new capability — such a process
  already owns the account — and the push carries no content.
- The hook lives in the operator's user settings, outside the repo; re-add it
  after a fresh box setup (see the snippet above).
- If Claude Code renames notification types, CLI pushes silently stop; the
  in-daemon path (ADR 0013) is unaffected.
